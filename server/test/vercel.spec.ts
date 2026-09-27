import { describe, expect, it } from 'vitest'
import { FREE_PLAN } from '../src/plans'
import {
  CONSUME_SCRIPT,
  HIT_ALL_SCRIPT,
  MemoryUsageCounter,
  REDIS_TIMEOUT_MS,
  RedisUsageCounter,
  type UsageCounter,
  expiresAt,
  redisConfigFromEnv,
} from '../src/usage'
import { createVercelApp, vercelClientIp } from '../src/vercel'
import { judgeText } from './fixtures'
import { TOKEN, freshUser } from './helpers'

const SEPT = new Date('2026-09-23T12:00:00Z')
const REDIS_URL = 'https://us1-merry-cat-32748.upstash.io' // host from the Upstash REST API docs
const REDIS_TOKEN = 'upstash-test-token'

/**
 * In-memory stand-in for the Upstash REST API (https://upstash.com/docs/redis/features/restapi):
 * POST <url> with a JSON command array -> {"result": ...}; POST <url>/multi-exec with an array of
 * commands -> [{"result": ...}, ...]. Implements GET / SET (EX) / INCR / EXPIREAT, and EVAL of the
 * two scripts in src/usage.ts (emulated in JS; the Lua itself is exercised against the real
 * Upstash by the deploy check, see README "Verification").
 */
function fakeUpstash() {
  const store = new Map<string, string>()
  const expiries = new Map<string, number>()
  const requests: { path: string; body: unknown; auth: string | null }[] = []
  const count = (k: string) => Number.parseInt(store.get(k) ?? '0', 10)
  const exec = (cmd: (string | number)[]): { result?: unknown; error?: string } => {
    const [name, key] = [String(cmd[0]).toUpperCase(), String(cmd[1])]
    switch (name) {
      case 'GET':
        return { result: store.get(key) ?? null }
      case 'SET':
        store.set(key, String(cmd[2]))
        if (String(cmd[3]).toUpperCase() === 'EX') expiries.set(key, Number(cmd[4]))
        return { result: 'OK' }
      case 'INCR': {
        const n = count(key) + 1
        store.set(key, String(n))
        return { result: n }
      }
      case 'EXPIREAT':
        expiries.set(key, Number(cmd[2]))
        return { result: 1 }
      case 'EVAL': {
        const [script, numkeys] = [cmd[1], Number(cmd[2])]
        const keys = cmd.slice(3, 3 + numkeys).map(String)
        const argv = cmd.slice(3 + numkeys).map(Number)
        if (script === CONSUME_SCRIPT) {
          const k = keys[0]!
          if (count(k) >= argv[0]!) return { result: -1 }
          store.set(k, String(count(k) + 1))
          expiries.set(k, argv[1]!)
          return { result: count(k) }
        }
        if (script === HIT_ALL_SCRIPT) {
          if (keys.some((k, i) => count(k) >= argv[i + 1]!)) return { result: 0 }
          for (const k of keys) {
            store.set(k, String(count(k) + 1))
            expiries.set(k, argv[0]!)
          }
          return { result: 1 }
        }
        return { error: 'ERR unknown script' }
      }
      default:
        return { error: `ERR unknown command '${name}'` }
    }
  }
  const fetchFn = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url)
    const auth = new Headers(init.headers).get('Authorization')
    const body = JSON.parse(String(init.body))
    requests.push({ path: url.pathname, body, auth })
    if (auth !== `Bearer ${REDIS_TOKEN}`) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
    const out = url.pathname === '/multi-exec' ? (body as (string | number)[][]).map(exec) : exec(body)
    return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } })
  }) as typeof fetch
  return { fetchFn, store, expiries, requests }
}

describe('redisConfigFromEnv', () => {
  it('reads the Vercel Marketplace names (KV_REST_API_*)', () => {
    expect(redisConfigFromEnv({ KV_REST_API_URL: `${REDIS_URL}/`, KV_REST_API_TOKEN: 't' })).toEqual({
      url: REDIS_URL,
      token: 't',
    })
  })
  it('reads the Upstash names (UPSTASH_REDIS_REST_*) first', () => {
    expect(
      redisConfigFromEnv({
        UPSTASH_REDIS_REST_URL: 'https://a.upstash.io',
        UPSTASH_REDIS_REST_TOKEN: 'a',
        KV_REST_API_URL: 'https://b.upstash.io',
        KV_REST_API_TOKEN: 'b',
      }),
    ).toEqual({ url: 'https://a.upstash.io', token: 'a' })
  })
  it('returns null when neither pair is complete', () => {
    expect(redisConfigFromEnv({ KV_REST_API_URL: REDIS_URL })).toBeNull()
  })
})

// The same behaviour is required from every counter store.
const stores: [string, () => UsageCounter][] = [
  ['memory', () => new MemoryUsageCounter()],
  ['redis', () => new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, fakeUpstash().fetchFn)],
]
for (const [name, make] of stores) {
  describe(`UsageCounter (${name})`, () => {
    it('counts up to the limit, then refuses without growing', async () => {
      const c = make()
      const u = freshUser()
      expect(await c.read(u, SEPT)).toBe(0)
      expect(await c.tryConsume(u, SEPT, 2)).toEqual({ ok: true, used: 1 })
      expect(await c.tryConsume(u, SEPT, 2)).toEqual({ ok: true, used: 2 })
      expect(await c.tryConsume(u, SEPT, 2)).toEqual({ ok: false })
      expect(await c.read(u, SEPT)).toBe(2)
    })

    it('counts every one of many concurrent fills, never above the limit', async () => {
      const c = make()
      const u = freshUser()
      const results = await Promise.all(Array.from({ length: 12 }, () => c.tryConsume(u, SEPT, 10)))
      expect(results.filter((r) => r.ok)).toHaveLength(10)
      expect(await c.read(u, SEPT)).toBe(10)
    })

    it('rate-limit windows: counts all keys or none', async () => {
      const c = make()
      const a = `rl:${freshUser()}`
      const b = `rl:${freshUser()}`
      expect(await c.tryHitAll([{ key: a, limit: 1 }, { key: b, limit: 3 }], 1_790_000_000)).toBe(true)
      expect(await c.tryHitAll([{ key: a, limit: 1 }, { key: b, limit: 3 }], 1_790_000_000)).toBe(false)
      expect(await c.tryHitAll([{ key: b, limit: 2 }], 1_790_000_000)).toBe(true) // b was counted once, not twice
      expect(await c.tryHitAll([{ key: b, limit: 2 }], 1_790_000_000)).toBe(false)
    })

    it('keeps months separate', async () => {
      const c = make()
      const u = freshUser()
      await c.tryConsume(u, SEPT, 5)
      expect(await c.read(u, new Date('2026-10-01T00:00:00Z'))).toBe(0)
    })
  })
}

describe('RedisUsageCounter wire format', () => {
  it('checks and counts in one EVAL under usage:<appUserID>:<YYYY-MM> (A3-10, D5)', async () => {
    const up = fakeUpstash()
    const c = new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, up.fetchFn)
    await c.tryConsume('user-1', SEPT, 10)
    const expireAt = Math.floor(expiresAt(SEPT).getTime() / 1000)
    expect(up.requests).toEqual([
      {
        path: '/',
        auth: `Bearer ${REDIS_TOKEN}`,
        body: ['EVAL', CONSUME_SCRIPT, 1, 'usage:user-1:2026-09', 10, expireAt],
      },
    ])
    expect(up.store.get('usage:user-1:2026-09')).toBe('1')
    expect(new Date(up.expiries.get('usage:user-1:2026-09')! * 1000).toISOString()).toBe('2026-10-08T00:00:00.000Z')
  })

  it('refuses at the limit with that single request: no DECR, count unchanged', async () => {
    const up = fakeUpstash()
    const c = new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, up.fetchFn)
    up.store.set('usage:user-1:2026-09', '10')
    expect(await c.tryConsume('user-1', SEPT, 10)).toEqual({ ok: false })
    expect(up.requests).toHaveLength(1)
    expect(JSON.stringify(up.requests)).not.toContain('DECR')
    expect(up.store.get('usage:user-1:2026-09')).toBe('10')
  })

  it('checks both rate-limit keys and counts both in one EVAL', async () => {
    const up = fakeUpstash()
    const c = new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, up.fetchFn)
    const hits = [
      { key: 'rl:a', limit: 2 },
      { key: 'rl:b', limit: 5 },
    ]
    expect(await c.tryHitAll(hits, 1_790_000_000)).toBe(true)
    expect(up.requests[0]!.body).toEqual(['EVAL', HIT_ALL_SCRIPT, 2, 'rl:a', 'rl:b', 1_790_000_000, 2, 5])
    expect(await c.tryHitAll(hits, 1_790_000_000)).toBe(true)
    expect(await c.tryHitAll(hits, 1_790_000_000)).toBe(false)
    expect(up.store.get('rl:b')).toBe('2')
  })

  it('stores the plan cache with SET ... EX', async () => {
    const up = fakeUpstash()
    const c = new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, up.fetchFn)
    await c.setPlan('user-1', { plan: 'pro', checkedAt: 5 }, 2_592_000)
    expect(up.requests[0]!.body).toEqual(['SET', 'plan:user-1', '{"plan":"pro","checkedAt":5}', 'EX', 2_592_000])
    expect(await c.getPlan('user-1')).toEqual({ plan: 'pro', checkedAt: 5 })
    expect(await c.getPlan('user-2')).toBeNull()
  })

  it('gives up on a slow Upstash after its timeout (A3-11, D5)', async () => {
    const hanging = (() => new Promise<Response>(() => {})) as typeof fetch
    const c = new RedisUsageCounter({ url: REDIS_URL, token: REDIS_TOKEN }, hanging, 30)
    const t0 = Date.now()
    await expect(c.read('user-1', SEPT)).rejects.toThrow()
    expect(Date.now() - t0).toBeLessThan(1000)
  })

  it('uses a 2 s timeout by default', () => {
    expect(REDIS_TIMEOUT_MS).toBe(2000)
  })

  it('rejects when Upstash rejects the token', async () => {
    const c = new RedisUsageCounter({ url: REDIS_URL, token: 'wrong' }, fakeUpstash().fetchFn)
    await expect(c.read('user-1', SEPT)).rejects.toThrow()
  })
})

describe('Vercel app (createVercelApp)', () => {
  const env = {
    APP_TOKEN: TOKEN,
    JEV_MODE: 'mock',
    REVENUECAT_MODE: 'mock',
    KV_REST_API_URL: REDIS_URL,
    KV_REST_API_TOKEN: REDIS_TOKEN,
  }
  const msg = (id: string, from: string, date: string, body: string) => ({
    id,
    text: judgeText({ from, to: 'user@example.com', subject: 'Your code', date, body }),
  })
  const acme = msg('A:1', 'Acme <no-reply@acme.co.uk>', '2026-09-23T10:00:00Z', 'Your Acme code is 482913.')
  const globex = msg('A:2', 'Globex <security@globex.com>', '2026-09-23T10:01:00Z', 'Use 771204 to sign in.')

  function client(e: Record<string, string | undefined> = env) {
    const up = fakeUpstash()
    const app = createVercelApp(e, { now: () => SEPT }, up.fetchFn)
    const user = freshUser()
    const req = (path: string, init: RequestInit = {}, token: string | null = TOKEN) => {
      const headers: Record<string, string> = { 'Content-Type': 'application/json', 'X-SkiPass-User': user }
      if (token !== null) headers['X-SkiPass-App-Token'] = token
      return app.request(path, { ...init, headers })
    }
    return { up, user, req }
  }

  it('returns 401 {"error":"unauthorized"} without the app token', async () => {
    const res = await client().req('/v1/usage', {}, null)
    expect(res.status).toBe(401)
    expect(await res.json()).toEqual({ error: 'unauthorized' })
  })

  it('serves judge, fills and usage with the contract shapes, counting in Redis', async () => {
    const c = client()
    const u0 = await c.req('/v1/usage')
    expect(u0.status).toBe(200)
    expect(await u0.json()).toEqual({
      plan: 'free',
      used: 0,
      limit: FREE_PLAN.monthlyFillLimit,
      resetsAt: '2026-10-01T00:00:00Z',
    })
    const j = await c.req('/v1/judge', {
      method: 'POST',
      body: JSON.stringify({ service: 'acme.co.uk', messages: [acme, globex] }),
    })
    expect(j.status).toBe(200)
    expect(await j.json()).toEqual({
      chosenId: 'A:1',
      scores: { 'A:1': 0.9, 'A:2': 0.1 },
      remaining: FREE_PLAN.monthlyFillLimit,
      source: 'mock',
    })
    const f = await c.req('/v1/fills', { method: 'POST', body: JSON.stringify({ messageId: 'A:1' }) })
    expect(f.status).toBe(200)
    expect(await f.json()).toEqual({ remaining: FREE_PLAN.monthlyFillLimit - 1 })
    expect(c.up.store.get(`usage:${c.user}:2026-09`)).toBe('1')
    expect(((await (await c.req('/v1/usage')).json()) as { used: number }).used).toBe(1)
  })

  it('returns 402 at the limit and keeps the stored count at the limit', async () => {
    const c = client()
    const fill = () => c.req('/v1/fills', { method: 'POST', body: JSON.stringify({ messageId: 'm' }) })
    for (let i = 0; i < FREE_PLAN.monthlyFillLimit; i++) expect((await fill()).status).toBe(200)
    const res = await fill()
    expect(res.status).toBe(402)
    expect(await res.json()).toEqual({ error: 'quota_exhausted', remaining: 0 })
    expect(c.up.store.get(`usage:${c.user}:2026-09`)).toBe(String(FREE_PLAN.monthlyFillLimit))
  })

  it('reads the app token from its environment (a different token is 401)', async () => {
    const res = await client({ ...env, APP_TOKEN: 'other' }).req('/v1/usage')
    expect(res.status).toBe(401)
  })

  it('rate-limits judge per user in Redis (429 rate_limited)', async () => {
    const up = fakeUpstash()
    const app = createVercelApp(env, { now: () => SEPT, judgeRateLimit: { perUser: 2, perIp: 50 } }, up.fetchFn)
    const user = freshUser()
    const judge = () =>
      app.request('/v1/judge', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-SkiPass-User': user, 'X-SkiPass-App-Token': TOKEN, 'X-Real-IP': '198.51.100.9' },
        body: JSON.stringify({ service: 'acme.co.uk', messages: [acme] }),
      })
    expect((await judge()).status).toBe(200)
    expect((await judge()).status).toBe(200)
    const res = await judge()
    expect(res.status).toBe(429)
    expect(await res.json()).toEqual({ error: 'rate_limited' })
    const hour = Math.floor(SEPT.getTime() / 3_600_000)
    expect(up.store.get(`rl:judge:user:${user}:${hour}`)).toBe('2')
    expect(up.store.get(`rl:judge:ip:198.51.100.9:${hour}`)).toBe('2')
  })

  it('takes the client IP from the headers Vercel sets, never from CF-Connecting-IP', () => {
    const req = (h: Record<string, string>) => new Request('https://x.example/v1/judge', { headers: h })
    expect(vercelClientIp(req({ 'x-vercel-forwarded-for': '198.51.100.1', 'x-real-ip': '198.51.100.2' }))).toBe('198.51.100.1')
    expect(vercelClientIp(req({ 'x-real-ip': '198.51.100.2' }))).toBe('198.51.100.2')
    expect(vercelClientIp(req({ 'x-forwarded-for': '198.51.100.3, 10.0.0.1' }))).toBe('198.51.100.3')
    expect(vercelClientIp(req({ 'cf-connecting-ip': '198.51.100.4' }))).toBe('unknown')
  })

  it('fails with 500 (not a silent zero) when no Redis is configured', async () => {
    const res = await client({ APP_TOKEN: TOKEN, JEV_MODE: 'mock', REVENUECAT_MODE: 'mock' }).req('/v1/usage')
    expect(res.status).toBe(500)
  })
})
