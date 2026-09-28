// Request handlers for the three API routes, written against the Web Request/Response API so the
// Vercel functions in api/ are one-line wrappers and tests can call these directly.
//
//   POST /api/send-code   {"email": "..."} (email optional when resending) -> 200 {sent, email, expiresAt, resendAt}
//   POST /api/verify-code {"code": "123456"} -> {result: verified | incorrect | locked | expired | no_session}
//   GET  /api/status      -> {active: false} | {active: true, email, expiresAt, resendAt, attemptsLeft}
//
// State lives in Upstash Redis (lib/store.ts); the cookie holds only a random session id.

import { buildCodeEmail, DEFAULT_SITE_URL, sendWithResend } from './email.js'
import { createHmac } from 'node:crypto'
import { CODE_TTL_MS, generateCode, hashCode, isSessionId, MAX_ATTEMPTS, newSessionId, RESEND_COOLDOWN_MS } from './otp.js'
import { type OtpStore, redisConfigFromEnv, RedisOtpStore } from './store.js'

export const COOKIE_NAME = 'sowbank_otp'

export interface Env {
  OTP_SECRET?: string
  RESEND_API_KEY?: string
  MAIL_FROM?: string
  /** Defaults to https://skipass-demo.vercel.app; the email names this URL. */
  SITE_URL?: string
  /** Upstash REST credentials (Vercel Marketplace names; UPSTASH_REDIS_REST_* also accepted). */
  KV_REST_API_URL?: string
  KV_REST_API_TOKEN?: string
  UPSTASH_REDIS_REST_URL?: string
  UPSTASH_REDIS_REST_TOKEN?: string
}

/** Sends allowed from one client IP per window. */
export const SEND_LIMIT_PER_IP = 5
export const SEND_IP_WINDOW_MS = 10 * 60 * 1000

export interface Deps {
  fetch: typeof fetch
  now: () => number
  generateCode: () => string
  /** Server-side OTP state for the environment; null when Upstash is not configured. */
  store: (env: Env) => OtpStore | null
}

export const defaultDeps: Deps = {
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  generateCode,
  store: (env) => {
    const cfg = redisConfigFromEnv({ ...env })
    return cfg === null ? null : new RedisOtpStore(cfg)
  },
}

/**
 * Client IP on Vercel: `x-vercel-forwarded-for`, else `x-real-ip`, else the first `x-forwarded-for`
 * entry. Vercel sets these and overwrites a client-sent X-Forwarded-For "to prevent IP spoofing"
 * (https://vercel.com/docs/headers/request-headers).
 */
export function clientIp(req: Request): string {
  const first = (v: string | null) => v?.split(',')[0]?.trim() || undefined
  const h = req.headers
  return first(h.get('x-vercel-forwarded-for')) ?? first(h.get('x-real-ip')) ?? first(h.get('x-forwarded-for')) ?? 'unknown'
}

/** Rate-limit key of a recipient: HMAC of the lowercased address, so the address itself is not a key. */
function recipientKey(email: string, secret: string): string {
  return `send:to:${createHmac('sha256', secret).update(email.toLowerCase()).digest('base64url')}`
}

// Pragmatic address check (one @, a dot in the domain, no spaces); the mail provider does the real validation.
const EMAIL_RE = /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', ...headers },
  })
}

export function getCookie(req: Request, name: string): string | undefined {
  const header = req.headers.get('cookie')
  if (!header) return undefined
  for (const part of header.split(';')) {
    const eq = part.indexOf('=')
    if (eq < 0) continue
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim()
  }
  return undefined
}

function isHttps(req: Request): boolean {
  const proto = req.headers.get('x-forwarded-proto')
  if (proto) return proto.split(',')[0]!.trim() === 'https'
  return new URL(req.url).protocol === 'https:'
}

function sessionCookie(req: Request, sessionId: string, expiresAt: number, now: number): string {
  const maxAge = Math.max(0, Math.ceil((expiresAt - now) / 1000))
  return `${COOKIE_NAME}=${sessionId}; Path=/; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${isHttps(req) ? '; Secure' : ''}`
}

function sessionIdFrom(req: Request): string | null {
  const v = getCookie(req, COOKIE_NAME)
  return isSessionId(v) ? v : null
}

function clearCookie(req: Request): string {
  return `${COOKIE_NAME}=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax${isHttps(req) ? '; Secure' : ''}`
}

async function readJson(req: Request): Promise<Record<string, unknown> | null> {
  try {
    const v: unknown = await req.json()
    return typeof v === 'object' && v !== null ? (v as Record<string, unknown>) : null
  } catch {
    return null
  }
}

/** Resend 401/403 error names that mean the API key itself is unusable (https://resend.com/docs/api-reference/errors). */
const KEY_ERRORS = new Set(['missing_api_key', 'invalid_api_key', 'restricted_api_key', 'suspended_api_key', 'invalid_permission'])

const NOT_CONFIGURED =(what: string) =>
  json(503, { error: 'not_configured', message: `The demo server is missing ${what}. Codes can't be sent until it is set.` })

export async function handleSendCode(req: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, { Allow: 'POST' })
  const secret = env.OTP_SECRET
  if (!secret) return NOT_CONFIGURED('OTP_SECRET')
  const store = deps.store(env)
  if (store === null) return NOT_CONFIGURED('its session store (Upstash KV_REST_API_URL/KV_REST_API_TOKEN)')

  const now = deps.now()
  const body = (await readJson(req)) ?? {}
  const previousId = sessionIdFrom(req)
  const previous = previousId === null ? null : await store.getSession(previousId, now)
  const typed = typeof body.email === 'string' ? body.email.trim() : ''
  const email = typed || previous?.email || ''
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return json(400, { error: 'invalid_email', message: 'Enter an email address like name@example.com.' })
  }
  if (!env.RESEND_API_KEY) return NOT_CONFIGURED('its email key (RESEND_API_KEY)')

  // Rate limits independent of cookies: 1 send per address per 30 s, 5 sends per IP per 10 min.
  // The slot is taken before calling Resend, so a failed send still waits out the cooldown.
  const reserved = await store.reserveSend(`send:ip:${clientIp(req)}`, recipientKey(email, secret), now, {
    ipLimit: SEND_LIMIT_PER_IP,
    ipWindowMs: SEND_IP_WINDOW_MS,
    recipientCooldownMs: RESEND_COOLDOWN_MS,
  })
  if (!reserved.ok) {
    const retryAfter = Math.max(1, Math.ceil(reserved.retryAfterMs / 1000))
    return json(
      429,
      { error: 'rate_limited', retryAfter, message: `Wait ${retryAfter} seconds before asking for another code.` },
      { 'Retry-After': String(retryAfter) },
    )
  }

  const code = deps.generateCode()
  const payload = buildCodeEmail({ to: email, code, siteUrl: env.SITE_URL || DEFAULT_SITE_URL, mailFrom: env.MAIL_FROM })
  const sent = await sendWithResend(env.RESEND_API_KEY, payload, deps.fetch)
  if (!sent.ok) {
    // 403 with a key-related name is a key problem, not the resend.dev recipient rule.
    if (sent.status === 403 && !KEY_ERRORS.has(sent.name ?? '')) {
      return json(403, {
        error: 'recipient_not_allowed',
        message:
          "This demo can only email the address that owns its mail account. Use that address, or ask the demo's owner to verify a sending domain.",
      })
    }
    if (sent.status === 429) {
      return json(503, { error: 'mail_quota', message: 'The demo has hit its email sending limit. Try again in a minute.' })
    }
    return json(502, { error: 'send_failed', message: "The code email couldn't be sent. Try again in a moment." })
  }

  // A new code replaces the previous one: the old session (and its code) stops working.
  if (previousId !== null) await store.deleteSession(previousId)
  const sessionId = newSessionId()
  const expiresAt = now + CODE_TTL_MS
  await store.createSession(sessionId, { email, codeHash: hashCode(code, secret), expiresAt, attempts: 0, sentAt: now })
  return json(
    200,
    { sent: true, email, expiresAt, resendAt: now + RESEND_COOLDOWN_MS },
    { 'Set-Cookie': sessionCookie(req, sessionId, expiresAt, now) },
  )
}

export async function handleVerifyCode(req: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, { Allow: 'POST' })
  const secret = env.OTP_SECRET
  if (!secret) return NOT_CONFIGURED('OTP_SECRET')
  const store = deps.store(env)
  if (store === null) return NOT_CONFIGURED('its session store (Upstash KV_REST_API_URL/KV_REST_API_TOKEN)')

  const body = await readJson(req)
  const code = typeof body?.code === 'string' ? body.code.replace(/\s/g, '') : ''
  if (!/^\d{6}$/.test(code)) return json(400, { error: 'invalid_code', message: 'Enter the 6 digits from the email.' })

  const sessionId = sessionIdFrom(req)
  if (sessionId === null) return json(200, { result: 'no_session' })

  // Attempts are counted server-side in one atomic step: replaying an old cookie or sending
  // guesses in parallel cannot reset or skip the count, and a verified session is deleted (single use).
  const r = await store.verify(sessionId, hashCode(code, secret), deps.now(), MAX_ATTEMPTS)
  switch (r.result) {
    case 'verified':
      return json(200, { result: 'verified', email: r.email }, { 'Set-Cookie': clearCookie(req) })
    case 'incorrect':
      return json(200, { result: 'incorrect', attemptsLeft: r.attemptsLeft })
    default:
      return json(200, { result: r.result })
  }
}

export async function handleStatus(req: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method !== 'GET') return json(405, { error: 'method_not_allowed' }, { Allow: 'GET' })
  const secret = env.OTP_SECRET
  const store = deps.store(env)
  const sessionId = sessionIdFrom(req)
  if (!secret || store === null || sessionId === null) return json(200, { active: false })
  const now = deps.now()
  const session = await store.getSession(sessionId, now)
  if (!session) return json(200, { active: false })
  const wait = await store.recipientWaitMs(recipientKey(session.email, secret), now)
  return json(200, {
    active: true,
    email: session.email,
    expiresAt: session.expiresAt,
    resendAt: now + wait,
    attemptsLeft: Math.max(0, MAX_ATTEMPTS - session.attempts),
  })
}
