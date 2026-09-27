# SkiPass — system definition (the "should")

Authoritative description of intended behaviour as of 2026-09-27, compiled by the orchestrator from the
user's decisions (SPEC_v2 "Decided" items and later chat decisions), `docs/CONTRACTS.md`, and verified
platform facts. Any difference between this document and the code is a finding. Items marked **[Open]**
are intentionally unimplemented and are NOT findings unless the code pretends to implement them.

## 0. Product in one paragraph

SkiPass is an iOS app + AutoFill Credential Provider extension. When the user focuses a one-time-code
field in Safari or an app, iOS shows a SkiPass suggestion above the standard keyboard
(`verification code for this website — SkiPass` / `From <mailbox address>`). Tapping it makes the
extension read recent mail from every registered mailbox (IMAP, incl. Gmail/Outlook via OAuth),
extract codes on-device, ask the server which email belongs to the requesting site (the server asks
Jev), and fill the chosen code. Plans (Free/Standard/Pro) limit fills per month via RevenueCat.

## 1. Components and deployment

| Component | Path | Runs on |
|---|---|---|
| App (SwiftUI) | `ios/App`, `ios/SkiPassUI` | iPhone, iOS 18+ (Liquid Glass on iOS 26+) |
| AutoFill extension | `ios/Extension` | same device |
| Shared core | `ios/SkiPassCore` (Models, Storage, Mail, Auth, AuthUI, Extraction, ServerClient) | app + extension (AuthUI app only) |
| Judge/usage server | `server/` (Hono) | Vercel project `skipass-server` (https://skipass-server.vercel.app), Upstash Redis; Cloudflare entry kept buildable |
| Demo site | `demo-web/` | Vercel project `skipass-demo` (https://skipass-demo.vercel.app), Resend |
| Legacy demo (unused) | `demo-site/` | not deployed; must still build/test or be clearly marked legacy |
| CI / packaging | `.github/workflows` (`ci`, `ipa`, `tour`, `probe`, `pages`, `live-sim`) | GitHub Actions macos-15 |

Identifiers: bundle `io.github.rkceve.skipass` (+`.autofill`); at runtime Sideloadly may append a
team suffix (e.g. `.LCUTH33TX7`). App Group / Keychain group are resolved at runtime (§6). Device IPAs
are built in **Debug** (RevenueCat Test Store key crashes Release by design) and named
`SkiPass-v<MARKETING_VERSION>-b<run>.ipa`, with `*.bundle/_CodeSignature` stripped.

## 2. App UI (decided)

- Name/title "SkiPass", subtitle as in Copy.swift. No settings gear (removed by user).
- Two tabs, native TabView: Home, Plan. Liquid Glass on controls only (Add button, tab bar); morph
  from Add into the sheet; spring expand/collapse of cards. Content cards are not glass.
- Home: list of registered mail addresses; "Add"; tapping a card expands it in place.
  - IMAP card expanded: incoming host/port (IMAP chip), username, masked password with reveal, Edit, Delete.
  - Google/Microsoft card expanded: no server rows; Delete only.
  - Add flow: email field (clear, validated, helper text) → Continue. gmail.com/googlemail.com →
    Google official sign-in (AppAuth, login_hint prefilled); outlook/hotmail/live/msn → Microsoft
    official sign-in; anything else → IMAP form (host, port 993 default, username, password) → Save.
  - Missing client ID → in-app error, never open the provider page.
  - Delete asks for confirmation.
- Plan: current plan card (name, "Current", tagline, remaining = limit − used this month, reset date);
  "Other plans" rows; low pressure (no banners/popups). Current plan = highest active tier.
  Tapping a paid plan purchases its package (Test Store modal). Upgrade immediate; downgrade to a
  lower paid tier = purchase that package (higher tier stays current until it ends); Free →
  `showManageSubscriptions` (cannot cancel Test Store; expires automatically). Taps during a purchase
  are ignored. Without a RevenueCat key: "Plans are unavailable in this build."
- All user-visible strings in `SkiPassUI/Copy.swift`, English.

## 3. AutoFill extension (decided)

1. `provideCredentialWithoutUserInteraction` with a one-time-code request: service = the identity's
   service identifier. Other request types → cancel `.credentialIdentityNotFound`.
2. Load mailboxes + credentials; fetch INBOX messages received in the last **10 minutes** from all
   mailboxes **in parallel**, **4 s budget each**, never marking messages read; skip failures.
3. Keep only messages where the extractor finds a code (2FHey port; subject first, then body; HTML→text).
4. Judge: server `/v1/judge` with full message text. `.chosen` → fill that message's code, then report
   the fill (`/v1/fills`) without blocking. Server `noMatch` or `quotaExhausted` → cancel silently
   (`.failed`, no UI). Server unreachable/timeout/5xx/401/bad reply → local fallback: newest message
   containing the requesting site's registrable domain, else newest message.
5. List / interface / text-insert paths: no custom UI; resolve and complete, else cancel `.userCanceled`.
6. Identity registration (background, no UI): bundled list of popular sign-in domains + demo domain
   `skipass-demo.vercel.app` + registrable domains seen in sender/links of code emails; label
   `From <first mailbox address>` **[Open: multi-mailbox labelling]**; refreshed on app launch,
   foreground, mailbox add/remove, and when the extension runs.

## 4. Server (contract = `docs/CONTRACTS.md` §5, with 2026-09-27 wording)

- Auth: `X-SkiPass-App-Token` must equal `APP_TOKEN` → else 401. `X-SkiPass-User` = RevenueCat app user ID.
- `POST /v1/judge` (no usage count): quota check (402 when used ≥ limit) runs concurrently with Jev;
  one Noul question per message, in parallel, 3 s timeout; pick highest noul ≥ 0.5, ties → newest
  `Date:`; none → `chosenId: null`; any Jev failure → fallback rule (as §3.4), `source: "fallback"`.
- `POST /v1/fills`: atomic increment of `usage:<user>:<YYYY-MM>` (UTC); 402 at limit.
- `GET /v1/usage`: plan (highest active entitlement among `standard`/`pro` via RevenueCat API v2, else
  free), used, limit, resetsAt (next UTC month start).
- Limits: free 10 / standard 100 / pro 1000 **[Open: values]**.
- Never log or persist email text/metadata. Secrets only in Vercel env.

## 5. Demo site

- Mobile-first fictional "Sowbank" sign-up: email → `/api/send-code` (Resend, awaited, subject
  `<code> is your Sowbank verification code`, body contains the code and `https://skipass-demo.vercel.app`)
  → `/verify` with `autocomplete="one-time-code"` 6-digit field; auto-submit on 6 digits; resend
  cooldown 30 s; 10-minute expiry; lock after 5 wrong attempts; stateless signed HttpOnly cookie.
- Resend sandbox: only the account owner's address receives mail; 403 shown clearly.

## 6. Storage and security

- App Group defaults: `mailboxes.v1`, `rc.appUserID`, `usage.snapshot.v1`, `identity.seenDomains.v1`.
- Keychain (not synchronizable, AfterFirstUnlockThisDeviceOnly): `password.<mailboxID>`,
  `oauth.<mailboxID>` (archived OIDAuthState). Group resolved at runtime so app and extension share
  it after re-signing; if sharing is impossible the app must still work and say so in logs.
- The app user ID written by the app must be the one the extension sends to the server.
- Secrets never in the repo; public keys (Google client ID, RevenueCat test key) via GitHub secrets.

## 7. Quality gates

`ci` green (core, ui-package, app+app tests, extension tests, server). Server `npm test` + typecheck.
Demo-web `npm test` + typecheck. Tour recording is not a gate.

## 8. Accepted trade-offs (decided in the 2026-09-27 audit triage)

- When the server is unreachable (timeout, 5xx, 401, 429, bad reply) the extension fills via the local
  fallback rule without a quota check; the fill is reported later if possible. Quota enforcement is
  therefore best-effort by design (demo resilience over strict metering).
- A fill happens before it is counted, so concurrent fills can pass the same quota check.
- The app token is embedded in the app and is public by nature; abuse is limited by rejecting unknown
  RevenueCat customers and rate-limiting `/v1/judge` (60/user/h, 300/IP/h).
- If RevenueCat is down the server uses the last known plan (fail-open when unknown) rather than
  downgrading a paying user.
- Keychain sharing between app and extension after re-signing can only be verified on a device; both
  processes log the resolved App Group and Keychain group.
