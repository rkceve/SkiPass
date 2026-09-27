// Server state: the monthly fill counter (key `usage:<appUserID>:<YYYY-MM>`, UTC, per
// docs/CONTRACTS.md §5), the judge rate-limit windows (`rl:judge:…`) and the last known plan per
// user (`plan:<appUserID>`). One interface, three stores:
//   - KvUsageCounter    — Cloudflare Workers KV (the Worker target).
//     KV API: get(key) / put(key, value, {expirationTtl}) —
//     https://developers.cloudflare.com/kv/api/write-key-value-pairs/
//     KV has no atomic operations, so concurrent requests can be counted once (README "Known limits").
//   - RedisUsageCounter — Upstash Redis REST API (the Vercel target). Atomic Lua scripts.
//     REST API: POST <url> with the command as a JSON array, `Authorization: Bearer <token>`,
//     response {"result": ...} / {"error": "..."} —
//     https://upstash.com/docs/redis/features/restapi ("POST Command in Body").
//     EVAL over REST: body ["EVAL", "<script>", <numkeys>, <keys...>, <args...>], response
//     {"result": <script reply>} — https://upstash.com/docs/redis/commands/scripting/eval ("REST API").
//     Lua number replies are Redis integers (JSON numbers); a Lua `false`/nil GET reply is nil.
//   - MemoryUsageCounter — in-process map, for tests.

import type { PlanId } from './plans.js'

export function monthKey(now: Date): string {
  const y = now.getUTCFullYear()
  const m = String(now.getUTCMonth() + 1).padStart(2, '0')
  return `${y}-${m}`
}

export function usageKey(appUserID: string, now: Date): string {
  return `usage:${appUserID}:${monthKey(now)}`
}

export function planKey(appUserID: string): string {
  return `plan:${appUserID}`
}

/** First instant of the next UTC month. */
export function resetsAt(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
}

/** ISO 8601 without fractional seconds, e.g. "2026-10-01T00:00:00Z". */
export function formatInstant(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

/** Keys expire a week after the month ends. */
export function expiresAt(now: Date): Date {
  return new Date(resetsAt(now).getTime() + 7 * 24 * 3600 * 1000)
}

function parseCount(raw: unknown): number {
  const n = typeof raw === 'number' ? raw : typeof raw === 'string' ? Number.parseInt(raw, 10) : 0
  return Number.isFinite(n) && n > 0 ? n : 0
}

/** Last plan RevenueCat reported for a user, and when (epoch ms). */
export interface PlanCacheEntry {
  plan: PlanId
  checkedAt: number
}

function parsePlanEntry(raw: unknown): PlanCacheEntry | null {
  if (typeof raw !== 'string') return null
  try {
    const v = JSON.parse(raw) as { plan?: unknown; checkedAt?: unknown }
    if (typeof v.plan !== 'string' || typeof v.checkedAt !== 'number') return null
    return { plan: v.plan as PlanId, checkedAt: v.checkedAt }
  } catch {
    return null
  }
}

export type ConsumeResult = { ok: true; used: number } | { ok: false }

/** One fixed-window counter checked by `tryHitAll`. */
export interface Hit {
  key: string
  limit: number
}

export interface UsageCounter {
  /** Fills counted for `appUserID` in the month of `now`. */
  read(appUserID: string, now: Date): Promise<number>
  /**
   * Counts one fill if fewer than `limit` have been counted this month. On success returns the
   * new count; at or over the limit returns `{ok: false}` and the count does not grow.
   */
  tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult>
  /**
   * Rate limiting: if every key is below its limit, counts one hit on each (keys expire at
   * `expireAtSec`, epoch seconds) and returns true; otherwise counts nothing and returns false.
   */
  tryHitAll(hits: Hit[], expireAtSec: number): Promise<boolean>
  /** Last known plan of a user (D2), or null. */
  getPlan(appUserID: string): Promise<PlanCacheEntry | null>
  setPlan(appUserID: string, entry: PlanCacheEntry, ttlSec: number): Promise<void>
}

/**
 * The subset of Workers KV (`KVNamespace`) used here. Declared structurally so the shared code
 * type-checks without the Workers type file (Vercel type-checks the Vercel entry on its own).
 */
export interface KvStore {
  get(key: string): Promise<string | null>
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>
}

/** KV `expirationTtl` is relative seconds with a minimum of 60. */
function kvTtl(expireAtSec: number, now: number): number {
  return Math.max(60, Math.ceil(expireAtSec - now / 1000))
}

/** Cloudflare Workers KV. Read-check-write: not atomic (KV has no increment). */
export class KvUsageCounter implements UsageCounter {
  constructor(private readonly kv: KvStore) {}

  async read(appUserID: string, now: Date): Promise<number> {
    return parseCount(await this.kv.get(usageKey(appUserID, now)))
  }

  async tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult> {
    const used = await this.read(appUserID, now)
    if (used >= limit) return { ok: false }
    const expirationTtl = kvTtl(expiresAt(now).getTime() / 1000, now.getTime())
    await this.kv.put(usageKey(appUserID, now), String(used + 1), { expirationTtl })
    return { ok: true, used: used + 1 }
  }

  async tryHitAll(hits: Hit[], expireAtSec: number): Promise<boolean> {
    const counts = await Promise.all(hits.map(async (h) => parseCount(await this.kv.get(h.key))))
    if (hits.some((h, i) => counts[i] >= h.limit)) return false
    const expirationTtl = kvTtl(expireAtSec, Date.now())
    await Promise.all(hits.map((h, i) => this.kv.put(h.key, String(counts[i] + 1), { expirationTtl })))
    return true
  }

  async getPlan(appUserID: string): Promise<PlanCacheEntry | null> {
    return parsePlanEntry(await this.kv.get(planKey(appUserID)))
  }

  async setPlan(appUserID: string, entry: PlanCacheEntry, ttlSec: number): Promise<void> {
    await this.kv.put(planKey(appUserID), JSON.stringify(entry), { expirationTtl: Math.max(60, ttlSec) })
  }
}

export interface RedisRestConfig {
  url: string
  token: string
}

/**
 * Upstash REST credentials from the environment. The Vercel Marketplace integration injects
 * `KV_REST_API_URL` / `KV_REST_API_TOKEN`; a database created in the Upstash console uses
 * `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN`. Both are accepted (Upstash names first).
 */
export function redisConfigFromEnv(env: Record<string, string | undefined>): RedisRestConfig | null {
  const pairs: [string | undefined, string | undefined][] = [
    [env.UPSTASH_REDIS_REST_URL, env.UPSTASH_REDIS_REST_TOKEN],
    [env.KV_REST_API_URL, env.KV_REST_API_TOKEN],
  ]
  for (const [url, token] of pairs) {
    if (url && token) return { url: url.replace(/\/+$/, ''), token }
  }
  return null
}

export class RedisError extends Error {}

/** Per-request budget for Upstash calls (D5), so a slow Redis fails the request fast. */
export const REDIS_TIMEOUT_MS = 2000

/**
 * KEYS[1] = counter, ARGV[1] = limit, ARGV[2] = EXPIREAT (epoch s).
 * Counts only below the limit; returns the new count, or -1 when at/over the limit (unchanged).
 */
export const CONSUME_SCRIPT = [
  "local n = tonumber(redis.call('GET', KEYS[1]) or '0')",
  'if n >= tonumber(ARGV[1]) then return -1 end',
  "n = redis.call('INCR', KEYS[1])",
  "redis.call('EXPIREAT', KEYS[1], ARGV[2])",
  'return n',
].join('\n')

/**
 * KEYS = window counters, ARGV[1] = EXPIREAT (epoch s), ARGV[i+1] = limit of KEYS[i].
 * Returns 1 and counts every key when all are below their limits; otherwise 0 and counts nothing.
 */
export const HIT_ALL_SCRIPT = [
  'for i, k in ipairs(KEYS) do',
  "  if tonumber(redis.call('GET', k) or '0') >= tonumber(ARGV[i + 1]) then return 0 end",
  'end',
  'for _, k in ipairs(KEYS) do',
  "  redis.call('INCR', k)",
  "  redis.call('EXPIREAT', k, ARGV[1])",
  'end',
  'return 1',
].join('\n')

/** Upstash Redis over its REST API. Check-and-count runs as one Lua script (atomic). */
export class RedisUsageCounter implements UsageCounter {
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
    private readonly timeoutMs: number = REDIS_TIMEOUT_MS,
  ) {}

  private async command(cmd: (string | number)[]): Promise<unknown> {
    const controller = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort()
        reject(new RedisError('redis timeout'))
      }, this.timeoutMs)
    })
    const work = (async () => {
      const res = await this.fetchFn(this.config.url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(cmd),
        signal: controller.signal,
      })
      if (!res.ok) throw new RedisError(`redis http ${res.status}`)
      return (await res.json()) as { result?: unknown; error?: string }
    })()
    try {
      const json = await Promise.race([work, deadline])
      if (json.error !== undefined) throw new RedisError('redis command error')
      return json.result
    } finally {
      if (timer !== undefined) clearTimeout(timer)
      work.catch(() => {}) // a late failure after the deadline is not an unhandled rejection
    }
  }

  async read(appUserID: string, now: Date): Promise<number> {
    return parseCount(await this.command(['GET', usageKey(appUserID, now)]))
  }

  async tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult> {
    const key = usageKey(appUserID, now)
    const expireAt = Math.floor(expiresAt(now).getTime() / 1000)
    const used = await this.command(['EVAL', CONSUME_SCRIPT, 1, key, limit, expireAt])
    if (typeof used !== 'number') throw new RedisError('redis unexpected script reply')
    return used < 0 ? { ok: false } : { ok: true, used }
  }

  async tryHitAll(hits: Hit[], expireAtSec: number): Promise<boolean> {
    const reply = await this.command([
      'EVAL',
      HIT_ALL_SCRIPT,
      hits.length,
      ...hits.map((h) => h.key),
      expireAtSec,
      ...hits.map((h) => h.limit),
    ])
    if (reply !== 0 && reply !== 1) throw new RedisError('redis unexpected script reply')
    return reply === 1
  }

  async getPlan(appUserID: string): Promise<PlanCacheEntry | null> {
    return parsePlanEntry(await this.command(['GET', planKey(appUserID)]))
  }

  async setPlan(appUserID: string, entry: PlanCacheEntry, ttlSec: number): Promise<void> {
    await this.command(['SET', planKey(appUserID), JSON.stringify(entry), 'EX', ttlSec])
  }
}

/** In-memory store (tests). Synchronous, therefore atomic. */
export class MemoryUsageCounter implements UsageCounter {
  readonly counts = new Map<string, number>()
  readonly plans = new Map<string, PlanCacheEntry>()

  async read(appUserID: string, now: Date): Promise<number> {
    return this.counts.get(usageKey(appUserID, now)) ?? 0
  }

  async tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult> {
    const key = usageKey(appUserID, now)
    const used = this.counts.get(key) ?? 0
    if (used >= limit) return { ok: false }
    this.counts.set(key, used + 1)
    return { ok: true, used: used + 1 }
  }

  async tryHitAll(hits: Hit[]): Promise<boolean> {
    if (hits.some((h) => (this.counts.get(h.key) ?? 0) >= h.limit)) return false
    for (const h of hits) this.counts.set(h.key, (this.counts.get(h.key) ?? 0) + 1)
    return true
  }

  async getPlan(appUserID: string): Promise<PlanCacheEntry | null> {
    return this.plans.get(appUserID) ?? null
  }

  async setPlan(appUserID: string, entry: PlanCacheEntry): Promise<void> {
    this.plans.set(appUserID, entry)
  }
}
