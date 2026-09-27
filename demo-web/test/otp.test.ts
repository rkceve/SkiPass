import { describe, expect, it } from 'vitest'
import {
  checkCode,
  CODE_TTL_MS,
  generateCode,
  hashCode,
  MAX_ATTEMPTS,
  newSession,
  readSession,
  RESEND_COOLDOWN_MS,
  resendWaitMs,
  signSession,
} from '../lib/otp.js'

const SECRET = 'test-secret-0123456789abcdef'
const T0 = 1_790_000_000_000

describe('generateCode', () => {
  it('returns 6 digits', () => {
    for (let i = 0; i < 200; i++) expect(generateCode()).toMatch(/^\d{6}$/)
  })
})

describe('hashCode', () => {
  it('is sha256(code + secret) in hex', () => {
    // sha256("123456" + "s") computed independently with `printf '123456s' | sha256sum`.
    expect(hashCode('123456', 's')).toBe('482ce8cca1f8acabcf1c9ab250d3993a9c3dd1ef3b55d4af222761912b576491')
    expect(hashCode('123456', SECRET)).not.toBe(hashCode('123457', SECRET))
    expect(hashCode('123456', SECRET)).not.toBe(hashCode('123456', 'other'))
  })
})

describe('signed session cookie', () => {
  const session = newSession('reader@example.com', '042917', SECRET, T0)

  it('round-trips', () => {
    expect(readSession(signSession(session, SECRET), SECRET)).toEqual(session)
  })

  it('does not contain the code in clear', () => {
    const token = signSession(session, SECRET)
    const payload = Buffer.from(token.split('.')[0]!, 'base64url').toString('utf8')
    expect(payload).not.toContain('042917')
    expect(payload).toContain(hashCode('042917', SECRET))
  })

  it('rejects a different secret', () => {
    expect(readSession(signSession(session, SECRET), 'wrong-secret')).toBeNull()
  })

  it('rejects a tampered payload (attempts reset)', () => {
    const token = signSession({ ...session, attempts: 4 }, SECRET)
    const [, sig] = token.split('.')
    const forged = Buffer.from(
      JSON.stringify({ e: session.email, h: session.codeHash, x: session.expiresAt, a: 0, s: session.sentAt }),
    ).toString('base64url')
    expect(readSession(`${forged}.${sig}`, SECRET)).toBeNull()
  })

  it('rejects garbage', () => {
    for (const t of [undefined, '', 'abc', 'a.b.c', '.x', 'eyJ9.sig']) expect(readSession(t, SECRET)).toBeNull()
  })

  it('sets expiry to 10 minutes after the send', () => {
    expect(session.expiresAt - T0).toBe(10 * 60 * 1000)
    expect(session.attempts).toBe(0)
    expect(session.sentAt).toBe(T0)
  })
})

describe('checkCode', () => {
  const session = newSession('reader@example.com', '042917', SECRET, T0)

  it('accepts the right code', () => {
    expect(checkCode(session, '042917', SECRET, T0 + 1000)).toEqual({ result: 'verified' })
  })

  it('counts a wrong code as an attempt', () => {
    const r = checkCode(session, '000000', SECRET, T0 + 1000)
    expect(r.result).toBe('incorrect')
    if (r.result !== 'incorrect') throw new Error('unreachable')
    expect(r.attemptsLeft).toBe(MAX_ATTEMPTS - 1)
    expect(r.session.attempts).toBe(1)
  })

  it('locks after MAX_ATTEMPTS wrong codes, even for the right code afterwards', () => {
    let s = session
    for (let i = 1; i < MAX_ATTEMPTS; i++) {
      const r = checkCode(s, '000000', SECRET, T0)
      if (r.result !== 'incorrect') throw new Error(`attempt ${i}: ${r.result}`)
      s = r.session
    }
    expect(checkCode(s, '000000', SECRET, T0).result).toBe('locked')
    expect(checkCode({ ...s, attempts: MAX_ATTEMPTS }, '042917', SECRET, T0).result).toBe('locked')
  })

  it('expires at exactly 10 minutes', () => {
    expect(checkCode(session, '042917', SECRET, T0 + CODE_TTL_MS - 1).result).toBe('verified')
    expect(checkCode(session, '042917', SECRET, T0 + CODE_TTL_MS).result).toBe('expired')
  })

  it('rejects the right code under another secret', () => {
    expect(checkCode(session, '042917', 'other', T0).result).toBe('incorrect')
  })
})

describe('resendWaitMs', () => {
  it('is 0 without a session and counts down 30 s after a send', () => {
    const s = newSession('a@b.co', '111111', SECRET, T0)
    expect(resendWaitMs(null, T0)).toBe(0)
    expect(resendWaitMs(s, T0)).toBe(RESEND_COOLDOWN_MS)
    expect(resendWaitMs(s, T0 + 29_000)).toBe(1_000)
    expect(resendWaitMs(s, T0 + 30_000)).toBe(0)
  })
})
