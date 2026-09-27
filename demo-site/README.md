# SkiPass demo site (Cloudflare Worker + Hono) — LEGACY

> **LEGACY — not deployed, not used in the demo. Superseded by [`../demo-web/`](../demo-web/)**
> (https://skipass-demo.vercel.app). Kept only as reference; CI still runs its tests and typecheck
> (`ci.yml`, job `demo-site`). Do not deploy it: its `/verify` has no attempt limit.

Originally the web page for the demo video: a fictional service's one-time-code entry screen.
Opening the page emails a fresh 6-digit code to one fixed, real mailbox (`DEMO_TO`); SkiPass reads
that mailbox and fills the code into `<input autocomplete="one-time-code">`.

| Route | Behaviour |
|---|---|
| `GET /` | The page: `SERVICE_NAME` logo text, "Enter verification code", the code field, Verify, a result line |
| `POST /send` | Called once by the page on load (per browser tab session). New code → KV `CODES` (`code:<session>`, TTL 10 min) → email to `DEMO_TO`. Max 1 send per 30 s per session (429 + `Retry-After`). Session = signed, HttpOnly cookie `demo_sid`, 10 min |
| `POST /verify` | `{"code":"123456"}` → `{"result":"correct" \| "incorrect" \| "expired"}` |

Email: From `<SERVICE_NAME> <MAIL_FROM>`, subject `Your <SERVICE_NAME> verification code is <code>`,
plain-text + HTML body with the code and a link to the page's own origin.

> **Sending method is provisional.** Resend was chosen by the orchestrator and still needs the
> user's confirmation. It sits behind the `Mailer` interface (`src/mailer.ts`), so another sender
> can replace it without touching the routes.

## Local

```sh
npm install
cp .dev.vars.example .dev.vars   # git-ignored; MAILER=log prints the code instead of sending
npm run dev                      # http://localhost:8787 ; the code appears in the terminal
npm test                         # vitest + @cloudflare/vitest-plugin (workerd)
npm run typecheck
```

## Configuration

| Name | Kind | Notes |
|---|---|---|
| `CODES` | KV binding | codes per session |
| `SERVICE_NAME` | var | fictional name on the page and in the email; default `Acme` |
| `DEMO_TO` | var | the demo mailbox; empty in `wrangler.jsonc` so no address is committed; pass at deploy |
| `MAIL_FROM` | var | default `onboarding@resend.dev` |
| `MAILER` | var | `resend` (default) or `log` |
| `RESEND_API_KEY` | secret | Resend API key (`re_...`) |
| `SESSION_SECRET` | secret | any long random string (signs the session cookie) |

## What you need to create

1. **A Resend account whose account email is the demo Gmail address.** Without a verified domain,
   Resend's `onboarding@resend.dev` sender "can only send emails to the email address associated
   with your Resend account" (https://resend.com/docs/knowledge-base/403-error-resend-dev-domain);
   any other `DEMO_TO` gets a 403 and the page shows no code. Create an API key in the Resend
   dashboard. Free tier: 100 emails/day (https://resend.com/pricing).
2. **A Cloudflare account** (Workers Free plan is enough).

## Deploy

```sh
npx wrangler login
npx wrangler kv namespace create CODES           # paste the printed id into wrangler.jsonc "kv_namespaces"[0].id
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put SESSION_SECRET
npm run deploy -- --var DEMO_TO:<demo gmail address> --var SERVICE_NAME:Acme
```

`--var` values are applied on every deploy, so pass `DEMO_TO` each time (a plain deploy resets it to
the empty value in `wrangler.jsonc`, and `/send` then answers 500).
The page is served at `https://skipass-demo.<subdomain>.workers.dev/` (HTTPS, as the one-time-code
AutoFill needs).

## Notes

- The Resend error body is never logged (it can echo the recipient address).
- KV is eventually consistent; the 30 s limit and 10 min lifetime are also checked against the
  stored send time, not only the KV TTL.
