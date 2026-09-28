// Server-side OTP state: sessions, attempt counts and send rate limits.
//
// Upstash Redis REST API (https://upstash.com/docs/redis/features/restapi):
//   POST <url> with the command as a JSON array, `Authorization: Bearer <token>` -> {"result": ...}
//   or {"error": "..."}; POST <url>/multi-exec with a 2-D array runs the commands as one transaction
//   -> [{"result": ...}, ...] ("Transactions").
// EVAL over REST: ["EVAL", "<script>", <numkeys>, <keys...>, <args...>] -> {"result": <reply>}
//   (https://upstash.com/docs/redis/commands/scripting/eval, "REST API"). A Lua table reply is a
//   JSON array; Lua numbers are Redis integers. Scripts run atomically, so checks and updates in
//   one script cannot interleave with other requests.
//
// Keys:
//   otp:<sessionId>        hash {e: email, h: sha256(code+secret), x: expiresAt ms, a: attempts, s: sentAt ms},
//                          expires at `x` (PEXPIREAT)
//   send:ip:<ip>           sends from one IP in the current window (PEXPIRE on the first send)
//   send:to:<hmac(email)>  exists for the resend cooldown after a send to that address (SET PX)

export interface OtpRecord {
  email: string
  codeHash: string
  expiresAt: number
  attempts: number
  sentAt: number
}

export type VerifyResult =
  | { result: 'verified'; email: string }
  | { result: 'incorrect'; attemptsLeft: number }
  | { result: 'locked' }
  | { result: 'expired' }
  | { result: 'no_session' }

export interface SendLimits {
  ipLimit: number
  ipWindowMs: number
  recipientCooldownMs: number
}

export type ReserveResult = { ok: true } | { ok: false; retryAfterMs: number }

export interface OtpStore {
  /**
   * Atomically: if the IP is under its window budget and the recipient is not cooling down, counts
   * one send for the IP and starts the recipient cooldown. Otherwise changes nothing and says how
   * long to wait.
   */
  reserveSend(ipKey: string, recipientKey: string, now: number, limits: SendLimits): Promise<ReserveResult>
  /** Milliseconds until the recipient may be sent another code (0 = now). */
  recipientWaitMs(recipientKey: string, now: number): Promise<number>
  createSession(sessionId: string, record: OtpRecord): Promise<void>
  getSession(sessionId: string, now: number): Promise<OtpRecord | null>
  deleteSession(sessionId: string): Promise<void>
  /** Atomically compares the code hash, counts a wrong attempt, locks at `maxAttempts`, deletes on success. */
  verify(sessionId: string, codeHash: string, now: number, maxAttempts: number): Promise<VerifyResult>
}

const sessionKey = (id: string) => `otp:${id}`

/** KEYS[1] = IP counter, KEYS[2] = recipient cooldown; ARGV = ip limit, ip window ms, cooldown ms. Returns {1, 0} or {0, waitMs}. */
export const RESERVE_SCRIPT = [
  "local n = tonumber(redis.call('GET', KEYS[1]) or '0')",
  "if n >= tonumber(ARGV[1]) then return {0, redis.call('PTTL', KEYS[1])} end",
  "local t = redis.call('PTTL', KEYS[2])",
  'if t > 0 then return {0, t} end',
  "if redis.call('INCR', KEYS[1]) == 1 then redis.call('PEXPIRE', KEYS[1], ARGV[2]) end",
  "redis.call('SET', KEYS[2], '1', 'PX', ARGV[3])",
  'return {1, 0}',
].join('\n')

/** KEYS[1] = session hash; ARGV = submitted code hash, now ms, max attempts. Returns {result, attemptsLeft[, email]}. */
export const VERIFY_SCRIPT = [
  "local s = redis.call('HMGET', KEYS[1], 'h', 'x', 'a', 'e')",
  "if not s[1] then return {'no_session', 0} end",
  "if tonumber(ARGV[2]) >= tonumber(s[2]) then return {'expired', 0} end",
  'local max = tonumber(ARGV[3])',
  'local a = tonumber(s[3])',
  "if a >= max then return {'locked', 0} end",
  "if s[1] == ARGV[1] then redis.call('DEL', KEYS[1]) return {'verified', 0, s[4]} end",
  "a = redis.call('HINCRBY', KEYS[1], 'a', 1)",
  "if a >= max then return {'locked', 0} end",
  "return {'incorrect', max - a}",
].join('\n')

export interface RedisRestConfig {
  url: string
  token: string
}

/**
 * Upstash REST credentials: `KV_REST_API_URL` / `KV_REST_API_TOKEN` (Vercel Marketplace integration)
 * or `UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` (Upstash console). Same rule as server/src/usage.ts.
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

/** Per-request budget for Upstash calls. */
export const REDIS_TIMEOUT_MS = 2000

export class RedisError extends Error {}

function parseRecord(fields: unknown): OtpRecord | null {
  if (!Array.isArray(fields) || fields.length === 0) return null
  const m = new Map<string, string>()
  for (let i = 0; i + 1 < fields.length; i += 2) m.set(String(fields[i]), String(fields[i + 1]))
  const [email, codeHash] = [m.get('e'), m.get('h')]
  const [expiresAt, attempts, sentAt] = [Number(m.get('x')), Number(m.get('a')), Number(m.get('s'))]
  if (email === undefined || codeHash === undefined || ![expiresAt, attempts, sentAt].every(Number.isFinite)) return null
  return { email, codeHash, expiresAt, attempts, sentAt }
}

export class RedisOtpStore implements OtpStore {
  constructor(
    private readonly config: RedisRestConfig,
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init),
    private readonly timeoutMs: number = REDIS_TIMEOUT_MS,
  ) {}

  private async post(path: string, body: unknown): Promise<unknown> {
    const controller = new AbortController()
    let timer: ReturnType<typeof setTimeout> | undefined
    const deadline = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        controller.abort()
        reject(new RedisError('redis timeout'))
      }, this.timeoutMs)
    })
    const work = (async () => {
      const res = await this.fetchFn(`${this.config.url}${path}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      })
      if (!res.ok) throw new RedisError(`redis http ${res.status}`)
      return (await res.json()) as unknown
    })()
    try {
      return await Promise.race([work, deadline])
    } finally {
      if (timer !== undefined) clearTimeout(timer)
      work.catch(() => {}) // a late failure after the deadline is not an unhandled rejection
    }
  }

  private async command(cmd: (string | number)[]): Promise<unknown> {
    const json = (await this.post('', cmd)) as { result?: unknown; error?: string }
    if (json.error !== undefined) throw new RedisError('redis command error')
    return json.result
  }

  async reserveSend(ipKey: string, recipientKey: string, _now: number, l: SendLimits): Promise<ReserveResult> {
    const r = await this.command(['EVAL', RESERVE_SCRIPT, 2, ipKey, recipientKey, l.ipLimit, l.ipWindowMs, l.recipientCooldownMs])
    if (!Array.isArray(r) || typeof r[0] !== 'number' || typeof r[1] !== 'number') throw new RedisError('redis unexpected reply')
    if (r[0] === 1) return { ok: true }
    // PTTL -1 (no expiry) cannot happen for keys this script writes; fall back to the full window.
    return { ok: false, retryAfterMs: r[1] > 0 ? r[1] : l.ipWindowMs }
  }

  async recipientWaitMs(recipientKey: string): Promise<number> {
    const t = await this.command(['PTTL', recipientKey])
    return typeof t === 'number' && t > 0 ? t : 0
  }

  async createSession(sessionId: string, r: OtpRecord): Promise<void> {
    const key = sessionKey(sessionId)
    const replies = await this.post('/multi-exec', [
      ['HSET', key, 'e', r.email, 'h', r.codeHash, 'x', r.expiresAt, 'a', r.attempts, 's', r.sentAt],
      ['PEXPIREAT', key, r.expiresAt],
    ])
    if (!Array.isArray(replies) || replies.some((x) => (x as { error?: string })?.error !== undefined)) {
      throw new RedisError('redis transaction error')
    }
  }

  async getSession(sessionId: string, now: number): Promise<OtpRecord | null> {
    const r = parseRecord(await this.command(['HGETALL', sessionKey(sessionId)]))
    return r !== null && now < r.expiresAt ? r : null
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.command(['DEL', sessionKey(sessionId)])
  }

  async verify(sessionId: string, codeHash: string, now: number, maxAttempts: number): Promise<VerifyResult> {
    const r = await this.command(['EVAL', VERIFY_SCRIPT, 1, sessionKey(sessionId), codeHash, now, maxAttempts])
    if (!Array.isArray(r)) throw new RedisError('redis unexpected reply')
    switch (r[0]) {
      case 'verified':
        return { result: 'verified', email: String(r[2]) }
      case 'incorrect':
        return { result: 'incorrect', attemptsLeft: Number(r[1]) }
      case 'locked':
      case 'expired':
      case 'no_session':
        return { result: r[0] }
      default:
        throw new RedisError('redis unexpected reply')
    }
  }
}

/** In-process store for tests. Every method finishes its read-modify-write without awaiting, so it is atomic. */
export class MemoryOtpStore implements OtpStore {
  private readonly sessions = new Map<string, OtpRecord>()
  private readonly counters = new Map<string, { n: number; until: number }>()
  private readonly cooldowns = new Map<string, number>()

  async reserveSend(ipKey: string, recipientKey: string, now: number, l: SendLimits): Promise<ReserveResult> {
    const c = this.counters.get(ipKey)
    const live = c !== undefined && c.until > now ? c : undefined
    if (live !== undefined && live.n >= l.ipLimit) return { ok: false, retryAfterMs: live.until - now }
    const wait = (this.cooldowns.get(recipientKey) ?? 0) - now
    if (wait > 0) return { ok: false, retryAfterMs: wait }
    this.counters.set(ipKey, live ? { n: live.n + 1, until: live.until } : { n: 1, until: now + l.ipWindowMs })
    this.cooldowns.set(recipientKey, now + l.recipientCooldownMs)
    return { ok: true }
  }

  async recipientWaitMs(recipientKey: string, now: number): Promise<number> {
    return Math.max(0, (this.cooldowns.get(recipientKey) ?? 0) - now)
  }

  async createSession(sessionId: string, record: OtpRecord): Promise<void> {
    this.sessions.set(sessionId, { ...record })
  }

  async getSession(sessionId: string, now: number): Promise<OtpRecord | null> {
    const r = this.sessions.get(sessionId)
    return r !== undefined && now < r.expiresAt ? { ...r } : null
  }

  async deleteSession(sessionId: string): Promise<void> {
    this.sessions.delete(sessionId)
  }

  async verify(sessionId: string, codeHash: string, now: number, maxAttempts: number): Promise<VerifyResult> {
    const r = this.sessions.get(sessionId)
    if (r === undefined) return { result: 'no_session' }
    if (now >= r.expiresAt) return { result: 'expired' }
    if (r.attempts >= maxAttempts) return { result: 'locked' }
    if (r.codeHash === codeHash) {
      this.sessions.delete(sessionId)
      return { result: 'verified', email: r.email }
    }
    r.attempts += 1
    if (r.attempts >= maxAttempts) return { result: 'locked' }
    return { result: 'incorrect', attemptsLeft: maxAttempts - r.attempts }
  }
}
