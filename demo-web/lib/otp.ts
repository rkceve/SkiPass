// Stateless one-time-code session.
//
// Nothing is stored server side. After a code is sent, the browser holds one HttpOnly cookie:
//   base64url(JSON payload) + "." + base64url(HMAC-SHA256(OTP_SECRET, base64url(JSON payload)))
// The payload carries the email, sha256(code + OTP_SECRET), the expiry, the attempt count and the
// send time (for the resend cooldown). Verification recomputes the hash from the submitted code.
//
// Limitation of the stateless design (acceptable for a demo): a client that keeps an old cookie can
// replay it, which resets the attempt counter or re-opens a verified session until it expires.

import { createHash, createHmac, randomInt, timingSafeEqual } from 'node:crypto'

export const CODE_LENGTH = 6
/** Code lifetime: 10 minutes. */
export const CODE_TTL_MS = 10 * 60 * 1000
/** Minimum time between two sends for one cookie. */
export const RESEND_COOLDOWN_MS = 30 * 1000
/** Wrong codes allowed before the session is locked. */
export const MAX_ATTEMPTS = 5

export interface OtpSession {
  /** Recipient address. */
  email: string
  /** Hex sha256(code + secret). */
  codeHash: string
  /** Epoch ms after which the code is no longer accepted. */
  expiresAt: number
  /** Wrong codes submitted so far. */
  attempts: number
  /** Epoch ms of the send (resend cooldown). */
  sentAt: number
}

/** Uniform 6-digit code from the CSPRNG (`crypto.randomInt` is unbiased). */
export function generateCode(): string {
  return String(randomInt(0, 10 ** CODE_LENGTH)).padStart(CODE_LENGTH, '0')
}

export function hashCode(code: string, secret: string): string {
  return createHash('sha256').update(code + secret).digest('hex')
}

export function newSession(email: string, code: string, secret: string, now: number): OtpSession {
  return { email, codeHash: hashCode(code, secret), expiresAt: now + CODE_TTL_MS, attempts: 0, sentAt: now }
}

function mac(data: string, secret: string): string {
  return createHmac('sha256', secret).update(data).digest('base64url')
}

export function signSession(session: OtpSession, secret: string): string {
  const body = Buffer.from(
    JSON.stringify({ e: session.email, h: session.codeHash, x: session.expiresAt, a: session.attempts, s: session.sentAt }),
    'utf8',
  ).toString('base64url')
  return `${body}.${mac(body, secret)}`
}

function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a)
  const y = Buffer.from(b)
  return x.length === y.length && timingSafeEqual(x, y)
}

/** Returns the session if the signature is valid and the payload well formed, otherwise null. */
export function readSession(token: string | undefined, secret: string): OtpSession | null {
  if (!token) return null
  const dot = token.indexOf('.')
  if (dot <= 0 || dot !== token.lastIndexOf('.')) return null
  const body = token.slice(0, dot)
  const sig = token.slice(dot + 1)
  if (!safeEqual(sig, mac(body, secret))) return null
  try {
    const p = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as Record<string, unknown>
    if (
      typeof p.e !== 'string' ||
      typeof p.h !== 'string' ||
      typeof p.x !== 'number' ||
      typeof p.a !== 'number' ||
      typeof p.s !== 'number'
    ) {
      return null
    }
    return { email: p.e, codeHash: p.h, expiresAt: p.x, attempts: p.a, sentAt: p.s }
  } catch {
    return null
  }
}

export type CheckResult =
  | { result: 'verified' }
  | { result: 'incorrect'; attemptsLeft: number; session: OtpSession }
  | { result: 'locked' }
  | { result: 'expired' }

/** Compares a submitted code against the session. On a wrong code returns the session with one more attempt. */
export function checkCode(session: OtpSession, code: string, secret: string, now: number): CheckResult {
  if (now >= session.expiresAt) return { result: 'expired' }
  if (session.attempts >= MAX_ATTEMPTS) return { result: 'locked' }
  if (safeEqual(hashCode(code, secret), session.codeHash)) return { result: 'verified' }
  const next = { ...session, attempts: session.attempts + 1 }
  if (next.attempts >= MAX_ATTEMPTS) return { result: 'locked' }
  return { result: 'incorrect', attemptsLeft: MAX_ATTEMPTS - next.attempts, session: next }
}

/** Milliseconds until another send is allowed for this session (0 = allowed now). */
export function resendWaitMs(session: OtpSession | null, now: number): number {
  if (!session) return 0
  return Math.max(0, session.sentAt + RESEND_COOLDOWN_MS - now)
}
