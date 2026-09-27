import { describe, expect, it, vi } from 'vitest'
import { buildCodeEmail, fromHeader, RESEND_URL, sendWithResend } from '../lib/email.js'
import { COOKIE_NAME, handleSendCode, handleStatus, handleVerifyCode, type Deps, type Env } from '../lib/handlers.js'

const SITE = 'https://skipass-demo.vercel.app'
const ENV: Env = { OTP_SECRET: 'test-secret-0123456789abcdef', RESEND_API_KEY: 're_test_key' }
const T0 = 1_790_000_000_000

// Fixtures from the Resend docs:
//   success: https://resend.com/docs/api-reference/emails/send-email ("Response")
//   403:     https://resend.com/docs/knowledge-base/403-error-resend-dev-domain (message text) with the
//            { statusCode, message, name } error shape of https://resend.com/docs/api-reference/errors
const RESEND_OK = { id: '49a3999c-0ce1-4ea6-ab68-afcd6dc2e794' }
const RESEND_403 = {
  statusCode: 403,
  message: 'You can only send testing emails to your own email address (owner@example.com).',
  name: 'validation_error',
}

function resendReturning(status: number, body: unknown) {
  return vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }),
  )
}

function deps(over: Partial<Deps> = {}): Deps {
  let t = T0
  return { fetch: resendReturning(200, RESEND_OK) as unknown as typeof fetch, now: () => t, generateCode: () => '042917', ...over }
}

function post(path: string, body: unknown, cookie?: string): Request {
  return new Request(`${SITE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(cookie ? { Cookie: cookie } : {}) },
    body: JSON.stringify(body),
  })
}

function cookieFrom(res: Response): string {
  const set = res.headers.get('set-cookie') ?? ''
  return set.split(';')[0]!
}

describe('code email', () => {
  it('has the subject, from, code and site URL the task fixes', () => {
    const p = buildCodeEmail({ to: 'reader@example.com', code: '042917', siteUrl: SITE })
    expect(p.from).toBe('Sowbank <onboarding@resend.dev>')
    expect(p.to).toEqual(['reader@example.com'])
    expect(p.subject).toBe('042917 is your Sowbank verification code')
    for (const part of [p.text, p.html]) {
      expect(part).toContain('042917')
      expect(part).toContain(SITE)
    }
  })

  it('keeps a MAIL_FROM that already has a display name', () => {
    expect(fromHeader('Sowbank <codes@sowbank.example>')).toBe('Sowbank <codes@sowbank.example>')
    expect(fromHeader('codes@sowbank.example')).toBe('Sowbank <codes@sowbank.example>')
    expect(fromHeader('')).toBe('Sowbank <onboarding@resend.dev>')
  })

  it('posts the documented request shape to Resend', async () => {
    const f = resendReturning(200, RESEND_OK)
    const p = buildCodeEmail({ to: 'reader@example.com', code: '042917', siteUrl: SITE })
    const r = await sendWithResend('re_xxxxxxxxx', p, f as unknown as typeof fetch)
    expect(r).toEqual({ ok: true, id: RESEND_OK.id })
    const [url, init] = f.mock.calls[0]!
    expect(url).toBe(RESEND_URL)
    expect(init?.method).toBe('POST')
    expect(init?.headers).toEqual({ Authorization: 'Bearer re_xxxxxxxxx', 'Content-Type': 'application/json' })
    const body = JSON.parse(String(init?.body)) as Record<string, unknown>
    expect(Object.keys(body).sort()).toEqual(['from', 'html', 'subject', 'text', 'to'])
    expect(body).toMatchObject({ from: 'Sowbank <onboarding@resend.dev>', to: ['reader@example.com'] })
  })

  it('reports Resend errors by status and name', async () => {
    const p = buildCodeEmail({ to: 'x@example.com', code: '1', siteUrl: SITE })
    expect(await sendWithResend('k', p, resendReturning(403, RESEND_403) as unknown as typeof fetch)).toEqual({
      ok: false,
      status: 403,
      name: 'validation_error',
    })
    const throwing = vi.fn(async () => {
      throw new Error('network')
    })
    expect(await sendWithResend('k', p, throwing as unknown as typeof fetch)).toEqual({ ok: false, status: 0 })
  })
})

describe('POST /api/send-code', () => {
  it('sends the email, then sets a signed HttpOnly SameSite=Lax cookie', async () => {
    const d = deps()
    const res = await handleSendCode(post('/api/send-code', { email: ' reader@example.com ' }), ENV, d)
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ sent: true, email: 'reader@example.com', expiresAt: T0 + 600_000, resendAt: T0 + 30_000 })
    const set = res.headers.get('set-cookie')!
    expect(set).toMatch(new RegExp(`^${COOKIE_NAME}=[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+;`))
    expect(set).toContain('HttpOnly')
    expect(set).toContain('SameSite=Lax')
    expect(set).toContain('Secure')
    expect(set).toContain('Max-Age=600')
    expect(set).not.toContain('042917')
    expect(d.fetch).toHaveBeenCalledOnce()
  })

  it('rejects a malformed address without sending', async () => {
    const d = deps()
    const res = await handleSendCode(post('/api/send-code', { email: 'not-an-email' }), ENV, d)
    expect(res.status).toBe(400)
    expect(d.fetch).not.toHaveBeenCalled()
  })

  it('rate-limits a second send within 30 s for the same cookie, and allows it after', async () => {
    let now = T0
    const d = deps({ now: () => now })
    const first = await handleSendCode(post('/api/send-code', { email: 'reader@example.com' }), ENV, d)
    const cookie = cookieFrom(first)
    now = T0 + 12_000
    const second = await handleSendCode(post('/api/send-code', {}, cookie), ENV, d)
    expect(second.status).toBe(429)
    expect(second.headers.get('retry-after')).toBe('18')
    now = T0 + 30_000
    const third = await handleSendCode(post('/api/send-code', {}, cookie), ENV, d)
    expect(third.status).toBe(200)
    expect(((await third.json()) as { email: string }).email).toBe('reader@example.com')
    expect(d.fetch).toHaveBeenCalledTimes(2)
  })

  it('explains the resend.dev owner-only rule on a Resend 403', async () => {
    const d = deps({ fetch: resendReturning(403, RESEND_403) as unknown as typeof fetch })
    const res = await handleSendCode(post('/api/send-code', { email: 'someone@example.com' }), ENV, d)
    expect(res.status).toBe(403)
    const body = (await res.json()) as { error: string; message: string }
    expect(body.error).toBe('recipient_not_allowed')
    expect(body.message).not.toContain('owner@example.com')
    expect(res.headers.get('set-cookie')).toBeNull()
  })

  it('treats a key-related 403 as a send failure, not the recipient rule', async () => {
    const d = deps({ fetch: resendReturning(403, { statusCode: 403, name: 'restricted_api_key', message: 'x' }) as unknown as typeof fetch })
    const res = await handleSendCode(post('/api/send-code', { email: 'someone@example.com' }), ENV, d)
    expect(res.status).toBe(502)
  })

  it('answers 503 not_configured without RESEND_API_KEY or OTP_SECRET', async () => {
    const d = deps()
    const noKey = await handleSendCode(post('/api/send-code', { email: 'a@example.com' }), { OTP_SECRET: 'x' }, d)
    expect(noKey.status).toBe(503)
    expect(((await noKey.json()) as { error: string }).error).toBe('not_configured')
    const noSecret = await handleSendCode(post('/api/send-code', { email: 'a@example.com' }), { RESEND_API_KEY: 'k' }, d)
    expect(noSecret.status).toBe(503)
    expect(d.fetch).not.toHaveBeenCalled()
  })

  it('rejects GET', async () => {
    expect((await handleSendCode(new Request(`${SITE}/api/send-code`), ENV, deps())).status).toBe(405)
  })
})

describe('POST /api/verify-code', () => {
  async function session(now = T0) {
    const res = await handleSendCode(post('/api/send-code', { email: 'reader@example.com' }), ENV, deps({ now: () => now }))
    return cookieFrom(res)
  }

  it('verifies the right code and clears the cookie', async () => {
    const cookie = await session()
    const res = await handleVerifyCode(post('/api/verify-code', { code: '042917' }, cookie), ENV, deps())
    expect(await res.json()).toEqual({ result: 'verified', email: 'reader@example.com' })
    expect(res.headers.get('set-cookie')).toContain('Max-Age=0')
  })

  it('counts wrong codes through the cookie and locks after 5', async () => {
    let cookie = await session()
    for (let left = 4; left >= 1; left--) {
      const res = await handleVerifyCode(post('/api/verify-code', { code: '111111' }, cookie), ENV, deps())
      expect(await res.json()).toEqual({ result: 'incorrect', attemptsLeft: left })
      cookie = cookieFrom(res)
    }
    const fifth = await handleVerifyCode(post('/api/verify-code', { code: '111111' }, cookie), ENV, deps())
    expect(await fifth.json()).toEqual({ result: 'locked' })
    cookie = cookieFrom(fifth)
    const right = await handleVerifyCode(post('/api/verify-code', { code: '042917' }, cookie), ENV, deps())
    expect(await right.json()).toEqual({ result: 'locked' })
  })

  it('reports expired after 10 minutes', async () => {
    const cookie = await session()
    const res = await handleVerifyCode(post('/api/verify-code', { code: '042917' }, cookie), ENV, deps({ now: () => T0 + 600_000 }))
    expect(await res.json()).toEqual({ result: 'expired' })
  })

  it('reports no_session without a cookie and 400 for a non-6-digit code', async () => {
    const none = await handleVerifyCode(post('/api/verify-code', { code: '042917' }), ENV, deps())
    expect(await none.json()).toEqual({ result: 'no_session' })
    const bad = await handleVerifyCode(post('/api/verify-code', { code: '12a' }), ENV, deps())
    expect(bad.status).toBe(400)
  })
})

describe('GET /api/status', () => {
  it('reports the pending session', async () => {
    const send = await handleSendCode(post('/api/send-code', { email: 'reader@example.com' }), ENV, deps())
    const req = new Request(`${SITE}/api/status`, { headers: { Cookie: cookieFrom(send) } })
    const res = await handleStatus(req, ENV, deps({ now: () => T0 + 10_000 }))
    expect(await res.json()).toEqual({
      active: true,
      email: 'reader@example.com',
      expiresAt: T0 + 600_000,
      resendAt: T0 + 30_000,
      attemptsLeft: 5,
    })
  })

  it('reports no session without a cookie', async () => {
    expect(await (await handleStatus(new Request(`${SITE}/api/status`), ENV, deps())).json()).toEqual({ active: false })
  })
})
