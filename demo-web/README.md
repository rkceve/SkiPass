# SkiPass demo sign-up site (Vercel)

A phone-first sign-up page for **Sowbank**, a fictional neighbourhood seed library. A visitor enters
an email address, gets a 6-digit code by email within seconds, and types (or AutoFills) it on a page
whose field is `<input autocomplete="one-time-code" inputmode="numeric">`, which is where the SkiPass
iOS AutoFill extension offers the code. Production: https://skipass-demo.vercel.app

The older single-mailbox Cloudflare version lives in `../demo-site/` and is unchanged.

## Flow

| Route | What it does |
|---|---|
| `GET /` | Sign-up page: email field, "Email me a code" |
| `POST /api/send-code` | `{"email"}` → sends the code email (awaited), sets the session cookie. Email may be omitted when resending with a cookie. 400 bad address, 429 + `Retry-After` within 30 s of the last send, 403 `recipient_not_allowed` on Resend's sandbox rule, 502 send failure, 503 `not_configured` |
| `GET /verify` | Code page (`autocomplete="one-time-code"`), resend with a 30 s countdown, verified / incorrect / locked / expired states. Six digits entered at once (AutoFill) are checked immediately |
| `POST /api/verify-code` | `{"code"}` → `{"result": "verified" \| "incorrect" (+attemptsLeft) \| "locked" \| "expired" \| "no_session"}` |
| `GET /api/status` | What the cookie says (email, expiry, resend time, attempts left), so `/verify` can restore itself |

## Stateless OTP

No database. After a send the browser holds one cookie `sowbank_otp` (HttpOnly, SameSite=Lax, Secure
on HTTPS, Max-Age = time left): `base64url(JSON{email, sha256(code + OTP_SECRET), expiry (10 min),
attempts, sentAt})` + `.` + `HMAC-SHA256(OTP_SECRET)`. Verification recomputes the hash from the
submitted code. 5 wrong codes lock the session; a new send starts a fresh one.

Known limits of the stateless design (fine for a demo): a client can replay an older cookie to reset
its attempt count or re-verify until expiry, and deleting the cookie skips the 30 s send limit.

## Why no framework

Three small endpoints. Vercel runs `api/*.ts` as Node.js functions with the Web-standard
`export default { fetch(request) }` signature
(https://vercel.com/docs/functions/runtimes/node-js#create-a-node.js-function-in-/api), and serves
`public/` as static files, so a framework would add dependencies without removing code. The handlers
in `lib/handlers.ts` take a `Request` and return a `Response`, which is also what the tests call.

## Email

Resend HTTP API, `POST https://api.resend.com/emails`
(https://resend.com/docs/api-reference/emails/send-email). From `Sowbank <MAIL_FROM>`, subject
`<code> is your Sowbank verification code`, text + HTML bodies with the code and
`https://skipass-demo.vercel.app` (SkiPass matches the code to the requesting site by this URL).

**Sandbox rule:** with the default `onboarding@resend.dev` sender, Resend "can only send emails to the
email address associated with your Resend account"
(https://resend.com/docs/knowledge-base/403-error-resend-dev-domain). Any other address gets a 403 and
the page says so. To email anyone, verify a domain in Resend and set `MAIL_FROM` to an address on it.

## Configuration (Vercel environment variables)

| Name | Required | Notes |
|---|---|---|
| `OTP_SECRET` | yes | random 32 bytes; signs the cookie and salts the code hash |
| `RESEND_API_KEY` | yes | `re_...`; without it `/api/send-code` answers 503 `not_configured` |
| `MAIL_FROM` | no | default `onboarding@resend.dev`; bare address or `Name <address>` |
| `SITE_URL` | no | URL written in the email; default `https://skipass-demo.vercel.app` |

## Commands

```sh
npm install
npm test            # vitest
npm run typecheck   # tsc --noEmit (also the Vercel build step)

npx vercel link --yes --project skipass-demo
printf '%s' "re_..." | npx vercel env add RESEND_API_KEY production
npx vercel deploy --prod
```

## Design plan

- **Subject:** a free seed library run by neighbours. Joining = getting a borrower card.
- **Colour:** tray `#e3e7d6` (sage page), kraft `#d8bb8a` (the seed packet), loam `#36281e` (text),
  chard `#9e2350` (actions, ruby chard stem), sprout `#3f6a1c` (success), frost `#fbfaf3` (fields).
- **Type:** Zilla Slab for headings (slab letterpress of old seed packets); Atkinson Hyperlegible for
  everything else, including the code digits, because its 0/O and 1/l/I are drawn to be told apart.
- **Layout:** one left-aligned column; the form sits in a kraft packet with a pinked top edge (the one
  bold element). Below it a three-step "How borrowing works", numbered because it is a sequence.
- **Motion:** only one moment: a rubber stamp "Card issued" presses onto the packet on success
  (skipped under reduced motion).
- **Changed after review:** a typewriter/monospace face for the card fields was dropped (monospace
  labels are a generated-page tell), and the default blue-button centred card was never considered.
