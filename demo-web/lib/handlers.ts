// Request handlers for the three API routes, written against the Web Request/Response API so the
// Vercel functions in api/ are one-line wrappers and tests can call these directly.
//
//   POST /api/send-code   {"email": "..."} (email optional when resending) -> 200 {sent, email, expiresAt, resendAt}
//   POST /api/verify-code {"code": "123456"} -> {result: verified | incorrect | locked | expired | no_session}
//   GET  /api/status      -> {active: false} | {active: true, email, expiresAt, resendAt, attemptsLeft}

import { buildCodeEmail, DEFAULT_SITE_URL, sendWithResend } from './email.js'
import {
  checkCode,
  generateCode,
  MAX_ATTEMPTS,
  newSession,
  readSession,
  RESEND_COOLDOWN_MS,
  resendWaitMs,
  signSession,
  type OtpSession,
} from './otp.js'

export const COOKIE_NAME = 'sowbank_otp'

export interface Env {
  OTP_SECRET?: string
  RESEND_API_KEY?: string
  MAIL_FROM?: string
  /** Defaults to https://skipass-demo.vercel.app; the email names this URL. */
  SITE_URL?: string
}

export interface Deps {
  fetch: typeof fetch
  now: () => number
  generateCode: () => string
}

export const defaultDeps: Deps = {
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  generateCode,
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

function sessionCookie(req: Request, session: OtpSession, secret: string, now: number): string {
  const maxAge = Math.max(0, Math.ceil((session.expiresAt - now) / 1000))
  return `${COOKIE_NAME}=${signSession(session, secret)}; Path=/; Max-Age=${maxAge}; HttpOnly; SameSite=Lax${isHttps(req) ? '; Secure' : ''}`
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

  const now = deps.now()
  const body = (await readJson(req)) ?? {}
  const previous = readSession(getCookie(req, COOKIE_NAME), secret)
  const typed = typeof body.email === 'string' ? body.email.trim() : ''
  const email = typed || previous?.email || ''
  if (!EMAIL_RE.test(email) || email.length > 254) {
    return json(400, { error: 'invalid_email', message: 'Enter an email address like name@example.com.' })
  }

  const wait = resendWaitMs(previous, now)
  if (wait > 0) {
    const retryAfter = Math.ceil(wait / 1000)
    return json(
      429,
      { error: 'rate_limited', retryAfter, message: `Wait ${retryAfter} seconds before asking for another code.` },
      { 'Retry-After': String(retryAfter) },
    )
  }

  if (!env.RESEND_API_KEY) return NOT_CONFIGURED('its email key (RESEND_API_KEY)')

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

  const session = newSession(email, code, secret, now)
  return json(
    200,
    { sent: true, email, expiresAt: session.expiresAt, resendAt: now + RESEND_COOLDOWN_MS },
    { 'Set-Cookie': sessionCookie(req, session, secret, now) },
  )
}

export async function handleVerifyCode(req: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' }, { Allow: 'POST' })
  const secret = env.OTP_SECRET
  if (!secret) return NOT_CONFIGURED('OTP_SECRET')

  const body = await readJson(req)
  const code = typeof body?.code === 'string' ? body.code.replace(/\s/g, '') : ''
  if (!/^\d{6}$/.test(code)) return json(400, { error: 'invalid_code', message: 'Enter the 6 digits from the email.' })

  const session = readSession(getCookie(req, COOKIE_NAME), secret)
  if (!session) return json(200, { result: 'no_session' })

  const now = deps.now()
  const r = checkCode(session, code, secret, now)
  switch (r.result) {
    case 'verified':
      return json(200, { result: 'verified', email: session.email }, { 'Set-Cookie': clearCookie(req) })
    case 'incorrect':
      return json(200, { result: 'incorrect', attemptsLeft: r.attemptsLeft }, { 'Set-Cookie': sessionCookie(req, r.session, secret, now) })
    case 'locked':
      // Keep the email (for "send a new code") but make every further check fail.
      return json(
        200,
        { result: 'locked' },
        { 'Set-Cookie': sessionCookie(req, { ...session, attempts: MAX_ATTEMPTS }, secret, now) },
      )
    case 'expired':
      return json(200, { result: 'expired' })
  }
}

export async function handleStatus(req: Request, env: Env, deps: Deps = defaultDeps): Promise<Response> {
  if (req.method !== 'GET') return json(405, { error: 'method_not_allowed' }, { Allow: 'GET' })
  const secret = env.OTP_SECRET
  const session = secret ? readSession(getCookie(req, COOKIE_NAME), secret) : null
  if (!session) return json(200, { active: false })
  const now = deps.now()
  return json(200, {
    active: true,
    email: session.email,
    expiresAt: session.expiresAt,
    resendAt: now + resendWaitMs(session, now),
    attemptsLeft: Math.max(0, MAX_ATTEMPTS - session.attempts),
  })
}
