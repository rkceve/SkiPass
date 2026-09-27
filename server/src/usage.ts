// Monthly fill counter: key `usage:<appUserID>:<YYYY-MM>` (UTC), per docs/CONTRACTS.md §5.
// One interface, three stores:
//   - KvUsageCounter    — Cloudflare Workers KV (the Worker target).
//     KV API: get(key) / put(key, value, {expirationTtl}) —
//     https://developers.cloudflare.com/kv/api/write-key-value-pairs/
//     KV has no atomic increment, so two concurrent fills can be counted once (README "Known limits").
//   - RedisUsageCounter — Upstash Redis REST API (the Vercel target). Atomic INCR.
//     REST API: POST <url> with a JSON array command, `Authorization: Bearer <token>`,
//     response {"result": ...} / {"error": "..."}; transactions via POST <url>/multi-exec with
//     an array of commands, response [{"result": ...}, ...] —
//     https://upstash.com/docs/redis/features/restapi ("POST Command in Body", "Transactions").
//   - MemoryUsageCounter — in-process map, for tests.

export function monthKey(now: Date): string {
  const y = now.getUTCFullYear()
  const m = String(now.getUTCMonth() + 1).padStart(2, '0')
  return `${y}-${m}`
}

export function usageKey(appUserID: string, now: Date): string {
  return `usage:${appUserID}:${monthKey(now)}`
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

export type ConsumeResult = { ok: true; used: number } | { ok: false }

export interface UsageCounter {
  /** Fills counted for `appUserID` in the month of `now`. */
  read(appUserID: string, now: Date): Promise<number>
  /**
   * Counts one fill if fewer than `limit` have been counted this month. On success returns the
   * new count; at or over the limit returns `{ok: false}` and the count does not grow.
   */
  tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult>
}

/**
 * The subset of Workers KV (`KVNamespace`) used here. Declared structurally so the shared code
 * type-checks without the Workers type file (Vercel type-checks the Vercel entry on its own).
 */
export interface KvStore {
  get(key: string): Promise<string | null>
  put(key: string, value: string, options?: { expirationTtl?: number }): Promise<void>
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
    // Relative TTL (seconds, minimum 60): always >= 7 days here.
    const expirationTtl = Math.ceil((expiresAt(now).getTime() - now.getTime()) / 1000)
    await this.kv.put(usageKey(appUserID, now), String(used + 1), { expirationTtl })
    return { ok: true, used: used + 1 }
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

/** Upstash Redis over its REST API. INCR is atomic, so concurrent fills are all counted. */
export class RedisUsageCounter implements UsageCounter {
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  private async post(path: string, body: unknown): Promise<unknown> {
    const res = await this.fetchFn(`${this.config.url}${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) throw new RedisError(`redis http ${res.status}`)
    return res.json()
  }

  private async command(cmd: (string | number)[]): Promise<unknown> {
    const json = (await this.post('', cmd)) as { result?: unknown; error?: string }
    if (json.error !== undefined) throw new RedisError('redis command error')
    return json.result
  }

  async read(appUserID: string, now: Date): Promise<number> {
    return parseCount(await this.command(['GET', usageKey(appUserID, now)]))
  }

  async tryConsume(appUserID: string, now: Date, limit: number): Promise<ConsumeResult> {
    const key = usageKey(appUserID, now)
    // INCR + EXPIREAT in one MULTI/EXEC transaction.
    const replies = (await this.post('/multi-exec', [
      ['INCR', key],
      ['EXPIREAT', key, Math.floor(expiresAt(now).getTime() / 1000)],
    ])) as { result?: unknown; error?: string }[] | { error?: string }
    if (!Array.isArray(replies) || replies[0]?.error !== undefined) {
      throw new RedisError('redis transaction error')
    }
    const used = replies[0]?.result
    if (typeof used !== 'number') throw new RedisError('redis unexpected INCR reply')
    if (used > limit) {
      // Over the limit: undo this increment, so the stored count stays at the limit.
      await this.command(['DECR', key])
      return { ok: false }
    }
    return { ok: true, used }
  }
}

/** In-memory store (tests). Synchronous, therefore atomic. */
export class MemoryUsageCounter implements UsageCounter {
  readonly counts = new Map<string, number>()

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
}
