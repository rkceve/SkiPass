import { describe, expect, it } from 'vitest'
import {
  MemoryOtpStore,
  REDIS_TIMEOUT_MS,
  RedisOtpStore,
  RESERVE_SCRIPT,
  VERIFY_SCRIPT,
  redisConfigFromEnv,
  type OtpStore,
} from '../lib/store.js'

const URL_ = 'https://us1-merry-cat-32748.upstash.io' // host from the Upstash REST API docs
const TOKEN = 'upstash-test-token'
const T0 = 1_790_000_000_000

/**
 * In-memory stand-in for the Upstash REST API (https://upstash.com/docs/redis/features/restapi):
 * POST <url> with one command -> {"result"}, POST <url>/multi-exec with several -> [{"result"}, ...].
 * EVAL of the two scripts in lib/store.ts is emulated in JS (the Lua runs against the real Upstash
 * in the deploy check). Time is the `now` the test controls.
 */
function fakeUpstash(clock: () => number) {
  const strings = new Map<string, string>()
  const hashes = new Map<string, Map<string, string>>()
  const expiry = new Map<string, number>()
  const requests: { path: string; body: unknown }[] = []
  const alive = (k: string) => {
    const e = expiry.get(k)
    if (e !== undefined && e <= clock()) {
      strings.delete(k)
      hashes.delete(k)
      expiry.delete(k)
    }
    return strings.has(k) || hashes.has(k)
  }
  const pttl = (k: string) => (!alive(k) ? -2 : expiry.has(k) ? expiry.get(k)! - clock() : -1)
  const exec = (cmd: (string | number)[]): { result?: unknown; error?: string } => {
    const name = String(cmd[0]).toUpperCase()
    const key = String(cmd[1])
    switch (name) {
      case 'HSET': {
        alive(key)
        const h = hashes.get(key) ?? new Map<string, string>()
        for (let i = 2; i < cmd.length; i += 2) h.set(String(cmd[i]), String(cmd[i + 1]))
        hashes.set(key, h)
        return { result: (cmd.length - 2) / 2 }
      }
      case 'HGETALL': {
        if (!alive(key)) return { result: [] }
        return { result: [...hashes.get(key)!].flat() }
      }
      case 'PEXPIREAT':
        expiry.set(key, Number(cmd[2]))
        return { result: 1 }
      case 'PTTL':
        return { result: pttl(key) }
      case 'DEL':
        return { result: [key].filter((k) => alive(k) && (strings.delete(k) || hashes.delete(k))).length }
      case 'EVAL': {
        const script = cmd[1]
        const nk = Number(cmd[2])
        const keys = cmd.slice(3, 3 + nk).map(String)
        const argv = cmd.slice(3 + nk).map(String)
        if (script === RESERVE_SCRIPT) {
          const [ipKey, toKey] = keys as [string, string]
          const n = alive(ipKey) ? Number(strings.get(ipKey)) : 0
          if (n >= Number(argv[0])) return { result: [0, pttl(ipKey)] }
          const t = pttl(toKey)
          if (t > 0) return { result: [0, t] }
          strings.set(ipKey, String(n + 1))
          if (n + 1 === 1) expiry.set(ipKey, clock() + Number(argv[1]))
          strings.set(toKey, '1')
          expiry.set(toKey, clock() + Number(argv[2]))
          return { result: [1, 0] }
        }
        if (script === VERIFY_SCRIPT) {
          const k = keys[0]!
          if (!alive(k)) return { result: ['no_session', 0] }
          const h = hashes.get(k)!
          const max = Number(argv[2])
          if (Number(argv[1]) >= Number(h.get('x'))) return { result: ['expired', 0] }
          let a = Number(h.get('a'))
          if (a >= max) return { result: ['locked', 0] }
          if (h.get('h') === argv[0]) {
            const email = h.get('e')!
            hashes.delete(k)
            return { result: ['verified', 0, email] }
          }
          a += 1
          h.set('a', String(a))
          if (a >= max) return { result: ['locked', 0] }
          return { result: ['incorrect', max - a] }
        }
        return { error: 'ERR unknown script' }
      }
      default:
        return { error: `ERR unknown command '${name}'` }
    }
  }
  const fetchFn = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url)
    const body = JSON.parse(String(init.body))
    requests.push({ path: url.pathname, body })
    if (new Headers(init.headers).get('Authorization') !== `Bearer ${TOKEN}`) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
    }
    const out = url.pathname === '/multi-exec' ? (body as (string | number)[][]).map(exec) : exec(body)
    return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } })
  }) as typeof fetch
  return { fetchFn, requests }
}

const record = { email: 'reader@example.com', codeHash: 'h1', expiresAt: T0 + 600_000, attempts: 0, sentAt: T0 }

// Both stores must behave the same.
const stores: [string, (clock: () => number) => OtpStore][] = [
  ['memory', () => new MemoryOtpStore()],
  ['redis', (clock) => new RedisOtpStore({ url: URL_, token: TOKEN }, fakeUpstash(clock).fetchFn)],
]

for (const [name, make] of stores) {
  describe(`OtpStore (${name})`, () => {
    it('reserveSend: one send per recipient per cooldown, and an IP budget', async () => {
      let now = T0
      const s = make(() => now)
      const limits = { ipLimit: 2, ipWindowMs: 600_000, recipientCooldownMs: 30_000 }
      expect(await s.reserveSend('ip:1', 'to:a', now, limits)).toEqual({ ok: true })
      now = T0 + 5_000
      expect(await s.reserveSend('ip:1', 'to:a', now, limits)).toEqual({ ok: false, retryAfterMs: 25_000 })
      expect(await s.reserveSend('ip:1', 'to:b', now, limits)).toEqual({ ok: true })
      const blocked = await s.reserveSend('ip:1', 'to:c', now, limits)
      expect(blocked).toEqual({ ok: false, retryAfterMs: 595_000 })
      now = T0 + 600_000
      expect(await s.reserveSend('ip:1', 'to:c', now, limits)).toEqual({ ok: true })
    })

    it('verify: counts attempts, locks at the max, deletes on success', async () => {
      const now = T0
      const s = make(() => now)
      await s.createSession('sid1', record)
      expect(await s.verify('sid1', 'wrong', now, 3)).toEqual({ result: 'incorrect', attemptsLeft: 2 })
      expect(await s.verify('sid1', 'wrong', now, 3)).toEqual({ result: 'incorrect', attemptsLeft: 1 })
      expect(await s.verify('sid1', 'wrong', now, 3)).toEqual({ result: 'locked' })
      expect(await s.verify('sid1', 'h1', now, 3)).toEqual({ result: 'locked' })
      await s.createSession('sid2', record)
      expect(await s.verify('sid2', 'h1', now, 3)).toEqual({ result: 'verified', email: 'reader@example.com' })
      expect(await s.verify('sid2', 'h1', now, 3)).toEqual({ result: 'no_session' })
      expect(await s.getSession('sid2', now)).toBeNull()
    })

    it('getSession / deleteSession / expiry', async () => {
      let now = T0
      const s = make(() => now)
      await s.createSession('sid3', record)
      expect(await s.getSession('sid3', now)).toEqual(record)
      expect(await s.verify('sid3', 'h1', T0 + 600_000, 5)).toEqual({ result: 'expired' })
      await s.deleteSession('sid3')
      expect(await s.getSession('sid3', now)).toBeNull()
      await s.createSession('sid4', record)
      now = T0 + 600_000
      expect(await s.getSession('sid4', now)).toBeNull()
    })
  })
}

describe('RedisOtpStore wire format', () => {
  it('uses one EVAL for reserve and verify, and HSET + PEXPIREAT in one transaction for a new session', async () => {
    const up = fakeUpstash(() => T0)
    const s = new RedisOtpStore({ url: URL_, token: TOKEN }, up.fetchFn)
    await s.reserveSend('send:ip:1', 'send:to:x', T0, { ipLimit: 5, ipWindowMs: 600_000, recipientCooldownMs: 30_000 })
    expect(up.requests[0]).toEqual({ path: '/', body: ['EVAL', RESERVE_SCRIPT, 2, 'send:ip:1', 'send:to:x', 5, 600_000, 30_000] })
    await s.createSession('sid', record)
    expect(up.requests[1]).toEqual({
      path: '/multi-exec',
      body: [
        ['HSET', 'otp:sid', 'e', record.email, 'h', 'h1', 'x', record.expiresAt, 'a', 0, 's', T0],
        ['PEXPIREAT', 'otp:sid', record.expiresAt],
      ],
    })
    await s.verify('sid', 'h1', T0, 5)
    expect(up.requests[2]).toEqual({ path: '/', body: ['EVAL', VERIFY_SCRIPT, 1, 'otp:sid', 'h1', T0, 5] })
  })

  it('fails fast on a slow Upstash (2 s budget by default)', async () => {
    expect(REDIS_TIMEOUT_MS).toBe(2000)
    const hanging = (() => new Promise<Response>(() => {})) as typeof fetch
    const s = new RedisOtpStore({ url: URL_, token: TOKEN }, hanging, 30)
    const t0 = Date.now()
    await expect(s.getSession('sid', T0)).rejects.toThrow()
    expect(Date.now() - t0).toBeLessThan(1000)
  })

  it('reads the Upstash or Vercel Marketplace variable names', () => {
    expect(redisConfigFromEnv({ KV_REST_API_URL: `${URL_}/`, KV_REST_API_TOKEN: 't' })).toEqual({ url: URL_, token: 't' })
    expect(redisConfigFromEnv({ UPSTASH_REDIS_REST_URL: URL_, UPSTASH_REDIS_REST_TOKEN: 'u' })).toEqual({ url: URL_, token: 'u' })
    expect(redisConfigFromEnv({})).toBeNull()
  })
})
