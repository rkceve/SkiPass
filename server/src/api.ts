// SkiPass server HTTP API — docs/CONTRACTS.md §5 is the binding contract for paths, headers,
// bodies and status codes. Bindings are read from `c.env` as in
// https://hono.dev/docs/getting-started/cloudflare-workers ("Bindings"). The same app runs on
// Vercel (src/vercel.ts), which passes its environment variables in as the bindings.
//
// Privacy: nothing here logs or persists message text or metadata. The only stored data is the
// per-user monthly fill count, hourly judge rate-limit counters and each user's last known plan
// (Workers KV or Upstash Redis). The only log lines are config errors (names, never values).

import { Hono, type Context } from 'hono'
import { type Bindings, type Deps, defaultDeps } from './env.js'
import { type JevConfig, type JudgeMessage, judgeMessages } from './jev.js'
import { type Plan, planById } from './plans.js'
import { type PlanLookup, type RevenueCatConfig, lookupPlan } from './revenuecat.js'
import { type PlanCacheEntry, formatInstant, resetsAt } from './usage.js'

export const APP_TOKEN_HEADER = 'X-SkiPass-App-Token'
export const USER_HEADER = 'X-SkiPass-User'

/** Request limits (not in CONTRACTS; defensive bounds). */
export const MAX_MESSAGES = 50
export const MAX_TEXT_LENGTH = 200_000
export const MAX_ID_LENGTH = 512
/** KV keys are limited to 512 bytes (developers.cloudflare.com/kv/platform/limits). */
export const MAX_USER_ID_LENGTH = 256

export { JUDGE_LIMIT_PER_IP_PER_HOUR, JUDGE_LIMIT_PER_USER_PER_HOUR } from './env.js'
/** A user RevenueCat confirmed is not checked again for this long. */
export const KNOWN_USER_CACHE_MS = 10 * 60 * 1000
/** How long the last known plan is kept for RevenueCat outages. */
export const PLAN_CACHE_TTL_S = 30 * 24 * 3600
/** Fill limit used when no plan is known (fail-open): effectively unlimited. */
const NO_LIMIT = Number.MAX_SAFE_INTEGER

type Env = {
  Bindings: Bindings
  Variables: {
    appUserID: string
    /** Plan fetched from RevenueCat by the known-user check in this request. */
    freshPlan: Plan | undefined
    /** RevenueCat already failed in this request (do not wait for it twice). */
    rcFailed: boolean | undefined
    /** Last known plan, as read by the known-user check. */
    cachedPlan: PlanCacheEntry | null | undefined
  }
}
type Ctx = Context<Env>

const unauthorized = (c: Ctx) => c.json({ error: 'unauthorized' }, 401)
// Malformed requests: CONTRACTS §5 defines no body, so this one mirrors the other error replies.
const invalidRequest = (c: Ctx) => c.json({ error: 'invalid_request' }, 400)
const quotaExhausted = (c: Ctx) => c.json({ error: 'quota_exhausted', remaining: 0 }, 402)
const unknownUser = (c: Ctx) => c.json({ error: 'unknown_user' }, 401)
const rateLimited = (c: Ctx) => c.json({ error: 'rate_limited' }, 429)

/** Jev mode: mock only when JEV_MODE=mock; live without a key is `unconfigured`. */
export function jevConfigFrom(env: Bindings): JevConfig {
  if (env.JEV_MODE === 'mock') return { mode: 'mock', apiKey: '' }
  const apiKey = env.JEV_API_KEY ?? ''
  return { mode: apiKey === '' ? 'unconfigured' : 'live', apiKey }
}

/** RevenueCat mode: mock only when REVENUECAT_MODE=mock. */
export function rcConfigFrom(env: Bindings): RevenueCatConfig {
  const secretKey = env.REVENUECAT_SECRET_KEY ?? ''
  const projectId = env.REVENUECAT_PROJECT_ID ?? ''
  if (env.REVENUECAT_MODE === 'mock') return { mode: 'mock', secretKey, projectId }
  return { mode: secretKey === '' || projectId === '' ? 'unconfigured' : 'live', secretKey, projectId }
}

/** Config errors as log lines (variable names only, never values). */
export function configProblems(env: Bindings): string[] {
  const out: string[] = []
  if (jevConfigFrom(env).mode === 'unconfigured') {
    out.push('config error: JEV_API_KEY is not set and JEV_MODE is not "mock"; every judge uses the fallback rule')
  }
  if (rcConfigFrom(env).mode === 'unconfigured') {
    out.push(
      'config error: REVENUECAT_SECRET_KEY or REVENUECAT_PROJECT_ID is not set and REVENUECAT_MODE is not "mock"; ' +
        'plans cannot be looked up (last known plan is used, else the quota is not enforced)',
    )
  }
  return out
}

/** Length-independent string comparison, so response timing does not leak the token prefix. */
function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const x = enc.encode(a)
  const y = enc.encode(b)
  let diff = x.length ^ y.length
  const n = Math.max(x.length, y.length)
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0)
  return diff === 0
}

async function readJson(c: Ctx): Promise<unknown> {
  try {
    return await c.req.json()
  } catch {
    return undefined
  }
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function parseJudgeBody(body: unknown): { service: string | null; messages: JudgeMessage[] } | null {
  if (!isRecord(body)) return null
  const { service, messages } = body
  if (service !== null && typeof service !== 'string') return null
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_MESSAGES) return null
  const out: JudgeMessage[] = []
  const seen = new Set<string>()
  for (const m of messages) {
    if (!isRecord(m)) return null
    const { id, text } = m
    if (typeof id !== 'string' || id === '' || id.length > MAX_ID_LENGTH || seen.has(id)) return null
    if (typeof text !== 'string' || text.length > MAX_TEXT_LENGTH) return null
    seen.add(id)
    out.push({ id, text })
  }
  return { service: service === '' ? null : service, messages: out }
}

export function createApp(overrides: Partial<Deps> = {}) {
  const deps: Deps = { ...defaultDeps, ...overrides }
  const app = new Hono<Env>()
  let configChecked = false

  // Auth: CONTRACTS §5 — missing/invalid app token -> 401 {"error":"unauthorized"}.
  app.use('/v1/*', async (c, next) => {
    if (!configChecked) {
      // Once per instance: a missing live credential is a config error in the logs.
      configChecked = true
      for (const problem of configProblems(c.env)) deps.log(problem)
    }
    const expected = c.env.APP_TOKEN
    const given = c.req.header(APP_TOKEN_HEADER)
    if (!expected || given === undefined || !safeEqual(given, expected)) return unauthorized(c)
    const user = c.req.header(USER_HEADER)?.trim()
    if (!user || user.length > MAX_USER_ID_LENGTH) return invalidRequest(c)
    c.set('appUserID', user)
    await next()
  })

  const store = (c: Ctx) => deps.usageCounter(c.env)

  // Rate limit: per user and per client IP, fixed UTC hour windows, checked and counted in
  // one atomic step. Runs before the known-user check, so random ids cannot drive RevenueCat calls.
  app.use('/v1/judge', async (c, next) => {
    const hour = Math.floor(deps.now().getTime() / 3_600_000)
    const ok = await store(c).tryHitAll(
      [
        { key: `rl:judge:user:${c.get('appUserID')}:${hour}`, limit: deps.judgeRateLimit.perUser },
        { key: `rl:judge:ip:${deps.clientIp(c.req.raw)}:${hour}`, limit: deps.judgeRateLimit.perIp },
      ],
      (hour + 1) * 3600 + 60,
    )
    if (!ok) return rateLimited(c)
    await next()
  })

  /** RevenueCat lookup; a successful one refreshes the user's last known plan (30 days). */
  const fetchPlan = async (c: Ctx): Promise<PlanLookup> => {
    const rc = rcConfigFrom(c.env)
    const r = await lookupPlan(deps, rc, c.get('appUserID'))
    if (r.kind === 'plan' && rc.mode === 'live') {
      const entry = { plan: r.plan.id, checkedAt: deps.now().getTime() }
      await store(c).setPlan(c.get('appUserID'), entry, PLAN_CACHE_TTL_S)
    }
    if (r.kind === 'error') c.set('rcFailed', true)
    return r
  }

  // Known-user check: an id RevenueCat does not know -> 401 unknown_user, before any Jev
  // call or count. A positive answer is trusted for 10 minutes. When RevenueCat fails the request
  // goes on (never block or downgrade a user because RevenueCat is down).
  app.use('/v1/*', async (c, next) => {
    if (rcConfigFrom(c.env).mode !== 'live') return next()
    const cached = await store(c).getPlan(c.get('appUserID'))
    c.set('cachedPlan', cached)
    const age = cached === null ? Infinity : deps.now().getTime() - cached.checkedAt
    if (age >= 0 && age < KNOWN_USER_CACHE_MS) return next()
    const r = await fetchPlan(c)
    if (r.kind === 'unknown_user') return unknownUser(c)
    if (r.kind === 'plan') c.set('freshPlan', r.plan)
    await next()
  })

  /**
   * The user's plan for this request: RevenueCat now, else the last known plan, else null
   * (nothing known: the quota is not enforced). `unknown_user` when RevenueCat does not know the id.
   */
  const currentPlan = async (c: Ctx): Promise<Plan | null | 'unknown_user'> => {
    const fresh = c.get('freshPlan')
    if (fresh !== undefined) return fresh
    if (!c.get('rcFailed')) {
      const r = await fetchPlan(c)
      if (r.kind === 'plan') return r.plan
      if (r.kind === 'unknown_user') return 'unknown_user'
    }
    let cached = c.get('cachedPlan')
    if (cached === undefined) cached = await store(c).getPlan(c.get('appUserID'))
    return cached === null ? null : (planById(cached.plan) ?? null)
  }

  /** Plan + usage for the current UTC month. */
  const quota = async (c: Ctx, now: Date) => {
    const [plan, used] = await Promise.all([currentPlan(c), store(c).read(c.get('appUserID'), now)])
    if (plan === 'unknown_user') return 'unknown_user' as const
    const remaining = plan === null ? 0 : Math.max(0, plan.monthlyFillLimit - used)
    return { plan, used, remaining }
  }

  // POST /v1/judge — checks quota, does NOT count usage.
  app.post('/v1/judge', async (c) => {
    const parsed = parseJudgeBody(await readJson(c))
    if (parsed === null) return invalidRequest(c)
    // The quota check (RevenueCat, up to the 3 s upstream timeout) and the Jev calls (3 s) run
    // concurrently so their latencies do not add up. `judgeMessages` never rejects (failures
    // become the fallback), so a failing quota check leaves no unhandled rejection behind.
    // When the quota turns out to be exhausted, the Jev result is discarded.
    const [q, result] = await Promise.all([
      quota(c, deps.now()),
      judgeMessages(deps, jevConfigFrom(c.env), parsed.service, parsed.messages),
    ])
    if (q === 'unknown_user') return unknownUser(c)
    if (q.plan !== null && q.used >= q.plan.monthlyFillLimit) return quotaExhausted(c)
    return c.json({
      chosenId: result.chosenId,
      scores: result.scores,
      remaining: q.remaining,
      source: result.source,
    })
  })

  // POST /v1/fills — counts exactly one fill.
  app.post('/v1/fills', async (c) => {
    const body = await readJson(c)
    if (!isRecord(body)) return invalidRequest(c)
    const { messageId } = body
    if (typeof messageId !== 'string' || messageId === '' || messageId.length > MAX_ID_LENGTH) {
      return invalidRequest(c)
    }
    const now = deps.now()
    const plan = await currentPlan(c)
    if (plan === 'unknown_user') return unknownUser(c)
    // The counter checks the limit and counts in one step (atomically on Redis). No known plan ->
    // counted without a limit (fail-open).
    const limit = plan === null ? NO_LIMIT : plan.monthlyFillLimit
    const r = await store(c).tryConsume(c.get('appUserID'), now, limit)
    if (!r.ok) return quotaExhausted(c)
    return c.json({ remaining: plan === null ? 0 : Math.max(0, limit - r.used) })
  })

  // GET /v1/usage — plan "unknown" (limit 0) only when RevenueCat fails and nothing is known.
  app.get('/v1/usage', async (c) => {
    const now = deps.now()
    const q = await quota(c, now)
    if (q === 'unknown_user') return unknownUser(c)
    return c.json({
      plan: q.plan === null ? 'unknown' : q.plan.id,
      used: q.used,
      limit: q.plan === null ? 0 : q.plan.monthlyFillLimit,
      resetsAt: formatInstant(resetsAt(now)),
    })
  })

  return app
}
