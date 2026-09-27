import { describe, expect, it } from 'vitest'
import { generateCode, hashCode, isSessionId, newSessionId } from '../lib/otp.js'

describe('generateCode', () => {
  it('returns 6 digits', () => {
    for (let i = 0; i < 200; i++) expect(generateCode()).toMatch(/^\d{6}$/)
  })
})

describe('hashCode', () => {
  it('is sha256(code + secret) in hex', () => {
    // sha256("123456" + "s") computed independently with `printf '123456s' | sha256sum`.
    expect(hashCode('123456', 's')).toBe('482ce8cca1f8acabcf1c9ab250d3993a9c3dd1ef3b55d4af222761912b576491')
    expect(hashCode('123456', 'x')).not.toBe(hashCode('123457', 'x'))
    expect(hashCode('123456', 'x')).not.toBe(hashCode('123456', 'other'))
  })
})

describe('session id', () => {
  it('is 32 random bytes in base64url (43 chars) and never repeats', () => {
    const ids = new Set(Array.from({ length: 100 }, () => newSessionId()))
    expect(ids.size).toBe(100)
    for (const id of ids) {
      expect(id).toMatch(/^[A-Za-z0-9_-]{43}$/)
      expect(isSessionId(id)).toBe(true)
    }
  })

  it('rejects anything else (old signed cookies, garbage)', () => {
    for (const t of [undefined, '', 'abc', 'a.b', `${'a'.repeat(43)}.sig`, 'x'.repeat(44), `${'a'.repeat(42)}=`]) {
      expect(isSessionId(t)).toBe(false)
    }
  })
})
