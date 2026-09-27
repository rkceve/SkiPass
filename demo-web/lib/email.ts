// Code email and its delivery through the Resend HTTP API.
//
// Resend "Send Email" (https://resend.com/docs/api-reference/emails/send-email, read 2026-09-27):
//   POST https://api.resend.com/emails
//   headers: Authorization: Bearer re_xxxxxxxxx, Content-Type: application/json
//   body: { from, to, subject, html, text }; `from` accepts "Name <email@example.com>", `to` a string or array
//   example response: {"id": "49a3999c-0ce1-4ea6-ab68-afcd6dc2e794"}
// Errors (https://resend.com/docs/api-reference/errors): JSON { statusCode, message, name }.
//   403 validation_error on the resend.dev sender: "You can only send testing emails to your own email
//   address" (https://resend.com/docs/knowledge-base/403-error-resend-dev-domain) - without a verified
//   domain, onboarding@resend.dev only delivers to the Resend account owner's address.

export const SERVICE_NAME = 'Sowbank'
export const DEFAULT_SITE_URL = 'https://skipass-demo.vercel.app'
export const DEFAULT_MAIL_FROM = 'onboarding@resend.dev'
export const RESEND_URL = 'https://api.resend.com/emails'

export interface EmailPayload {
  from: string
  to: string[]
  subject: string
  text: string
  html: string
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

/** `MAIL_FROM` may be a bare address or already "Name <address>"; a bare address gets the service name. */
export function fromHeader(mailFrom: string | undefined): string {
  const v = (mailFrom ?? '').trim()
  if (v.includes('<')) return v
  return `${SERVICE_NAME} <${v || DEFAULT_MAIL_FROM}>`
}

export function buildCodeEmail(opts: { to: string; code: string; siteUrl: string; mailFrom?: string }): EmailPayload {
  const { to, code, siteUrl } = opts
  const host = new URL(siteUrl).host
  const subject = `${code} is your ${SERVICE_NAME} verification code`
  const text = [
    `${code} is your ${SERVICE_NAME} verification code.`,
    '',
    `Enter it on ${siteUrl} to finish setting up your borrower card. It expires in 10 minutes.`,
    '',
    `If you didn't ask for this, ignore this email. Nobody can join with your address without the code.`,
    '',
    `${SERVICE_NAME} seed library - ${siteUrl}`,
  ].join('\n')
  const url = escapeHtml(siteUrl)
  const html = `<!doctype html>
<html lang="en"><body style="margin:0;padding:0;background:#e4e8da;">
<div style="max-width:480px;margin:0 auto;padding:28px 20px;font-family:Georgia,'Times New Roman',serif;color:#33261d;">
<p style="margin:0 0 20px;font-size:18px;font-weight:bold;">${SERVICE_NAME}</p>
<div style="background:#d9bd8c;border-radius:6px;padding:22px 20px;">
<p style="margin:0 0 10px;font-size:16px;">Your verification code:</p>
<p style="margin:0 0 12px;font-size:36px;font-weight:bold;letter-spacing:8px;">${code}</p>
<p style="margin:0;font-size:15px;">Enter it on <a href="${url}" style="color:#a3214f;">${escapeHtml(host)}</a> to finish setting up your borrower card. It expires in 10 minutes.</p>
</div>
<p style="margin:20px 0 0;font-size:13px;line-height:1.5;">If you didn't ask for this, ignore this email. Nobody can join with your address without the code.<br>${url}</p>
</div>
</body></html>`
  return { from: fromHeader(opts.mailFrom), to: [to], subject, text, html }
}

export type SendResult =
  | { ok: true; id: string }
  | { ok: false; status: number; name?: string }

/**
 * Sends the email and waits for Resend's answer, so the message has left before the request returns.
 * The error message is not returned or logged: it can echo the account owner's address.
 */
export async function sendWithResend(apiKey: string, payload: EmailPayload, fetchFn: typeof fetch): Promise<SendResult> {
  let res: Response
  try {
    res = await fetchFn(RESEND_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
  } catch {
    return { ok: false, status: 0 }
  }
  const body = (await res.json().catch(() => null)) as { id?: unknown; name?: unknown } | null
  if (res.ok && body && typeof body.id === 'string') return { ok: true, id: body.id }
  return { ok: false, status: res.ok ? 502 : res.status, name: typeof body?.name === 'string' ? body.name : undefined }
}
