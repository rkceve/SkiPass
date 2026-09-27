// One-time codes and session ids.
//
// The session state (email, code hash, expiry, attempt count) lives server-side in Upstash Redis
// (lib/store.ts); the browser's HttpOnly cookie carries only a random session id. The code is
// never stored in clear: the store keeps sha256(code + OTP_SECRET) and verification compares hashes.

import { createHash, randomBytes, randomInt } from 'node:crypto'

export const CODE_LENGTH = 6
/** Code lifetime: 10 minutes. */
export const CODE_TTL_MS = 10 * 60 * 1000
/** Minimum time between two sends to one address. */
export const RESEND_COOLDOWN_MS = 30 * 1000
/** Wrong codes allowed before the session is locked. */
export const MAX_ATTEMPTS = 5

/** Uniform 6-digit code from the CSPRNG (`crypto.randomInt` is unbiased). */
export function generateCode(): string {
  return String(randomInt(0, 10 ** CODE_LENGTH)).padStart(CODE_LENGTH, '0')
}

export function hashCode(code: string, secret: string): string {
  return createHash('sha256').update(code + secret).digest('hex')
}

/** 32 bytes from the CSPRNG, base64url without padding (43 characters). */
export function newSessionId(): string {
  return randomBytes(32).toString('base64url')
}

export function isSessionId(v: string | undefined): v is string {
  return typeof v === 'string' && /^[A-Za-z0-9_-]{43}$/.test(v)
}
