// SkiPass server HTTP API — docs/CONTRACTS.md §5 is the binding contract for paths, headers,
// bodies and status codes. Bindings are read from `c.env` as in
// https://hono.dev/docs/getting-started/cloudflare-workers ("Bindings"). The same app runs on
// Vercel (src/vercel.ts), which passes its environment variables in as the bindings.
//
// Privacy: nothing here logs or persists message text or metadata. The only stored data is the
// per-user monthly fill count (Workers KV or Upstash Redis).

import { Hono, type Context } from 'hono'
import { type Bindings, type Deps, defaultDeps } from './env.js'
import { type JudgeMessage, judgeMessages } from './jev.js'
import { lookupPlan } from './revenuecat.js'
import { formatInstant, resetsAt } from './usage.js'

export const APP_TOKEN_HEADER = 'X-SkiPass-App-Token'
export const USER_HEADER = 'X-SkiPass-User'

/** Request limits (not in CONTRACTS; defensive bounds). */
export const MAX_MESSAGES = 50
export const MAX_TEXT_LENGTH = 200_000
export const MAX_ID_LENGTH = 512
/** KV keys are limited to 512 bytes (developers.cloudflare.com/kv/platform/limits). */
export const MAX_USER_ID_LENGTH = 256

type Env = { Bindings: Bindings; Variables: { appUserID: string } }
type Ctx = Context<Env>

const unauthorized = (c: Ctx) => c.json({ error: 'unauthorized' }, 401)
// OPEN(api): CONTRACTS §5 defines no body for malformed requests; this shape is provisional.
const invalidRequest = (c: Ctx) => c.json({ error: 'invalid_request' }, 400)
const quotaExhausted = (c: Ctx) => c.json({ error: 'quota_exhausted', remaining: 0 }, 402)

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

  // Auth: CONTRACTS §5 — missing/invalid app token -> 401 {"error":"unauthorized"}.
  app.use('/v1/*', async (c, next) => {
    const expected = c.env.APP_TOKEN
    const given = c.req.header(APP_TOKEN_HEADER)
    if (!expected || given === undefined || !safeEqual(given, expected)) return unauthorized(c)
    const user = c.req.header(USER_HEADER)?.trim()
    if (!user || user.length > MAX_USER_ID_LENGTH) return invalidRequest(c)
    c.set('appUserID', user)
    await next()
  })

  const jevConfig = (c: Ctx) => {
    const key = c.env.JEV_API_KEY ?? ''
    return { mode: c.env.JEV_MODE === 'mock' || key === '' ? 'mock' : 'live', apiKey: key } as const
  }
  const rcConfig = (c: Ctx) => {
    const key = c.env.REVENUECAT_SECRET_KEY ?? ''
    const projectId = c.env.REVENUECAT_PROJECT_ID ?? ''
    return {
      mode: c.env.REVENUECAT_MODE === 'mock' || key === '' || projectId === '' ? 'mock' : 'live',
      secretKey: key,
      projectId,
    } as const
  }

  /** Plan + usage for the current UTC month. */
  const quota = async (c: Ctx, now: Date) => {
    const user = c.get('appUserID')
    const [plan, used] = await Promise.all([
      lookupPlan(deps, rcConfig(c), user),
      deps.usageCounter(c.env).read(user, now),
    ])
    return { user, plan, used, remaining: Math.max(0, plan.monthlyFillLimit - used) }
  }

  // POST /v1/judge — checks quota, does NOT count usage.
  app.post('/v1/judge', async (c) => {
    const parsed = parseJudgeBody(await readJson(c))
    if (parsed === null) return invalidRequest(c)
    // The quota check (RevenueCat, up to the 2 s upstream timeout) and the Jev calls (2 s) run
    // concurrently so their latencies do not add up. `judgeMessages` never rejects (failures
    // become the fallback), so a failing quota check leaves no unhandled rejection behind.
    // When the quota turns out to be exhausted, the Jev result is discarded.
    const [q, result] = await Promise.all([
      quota(c, deps.now()),
      judgeMessages(deps, jevConfig(c), parsed.service, parsed.messages),
    ])
    if (q.used >= q.plan.monthlyFillLimit) return quotaExhausted(c)
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
    const user = c.get('appUserID')
    const plan = await lookupPlan(deps, rcConfig(c), user)
    // The counter checks the limit and counts in one step (atomically on Redis).
    const r = await deps.usageCounter(c.env).tryConsume(user, now, plan.monthlyFillLimit)
    if (!r.ok) return quotaExhausted(c)
    return c.json({ remaining: Math.max(0, plan.monthlyFillLimit - r.used) })
  })

  // GET /v1/usage
  app.get('/v1/usage', async (c) => {
    const now = deps.now()
    const q = await quota(c, now)
    return c.json({
      plan: q.plan.id,
      used: q.used,
      limit: q.plan.monthlyFillLimit,
      resetsAt: formatInstant(resetsAt(now)),
    })
  })

  return app
}
