# Architecture

SkiPass is an iOS app plus an AutoFill Credential Provider extension. When the user focuses a one-time-code field in Safari or an app, iOS shows a SkiPass suggestion above the keyboard. Tapping it makes the extension read recent mail from every registered mailbox over IMAP (including Gmail and Outlook.com through OAuth), extract codes on the device, ask the server which email belongs to the requesting site (the server asks Jev), and fill the chosen code. Plans (Free, Standard, Pro) limit fills per month through RevenueCat.

See also: [API.md](API.md) for the server HTTP API and [DECISIONS.md](DECISIONS.md) for the reasoning behind the main choices.

## 1. Components and deployment

| Component | Path | Runs on |
|---|---|---|
| App (SwiftUI) | `ios/App`, `ios/SkiPassUI` | iPhone, iOS 18+ (Liquid Glass controls on iOS 26+) |
| AutoFill extension | `ios/Extension` | Same device |
| Shared core | `ios/SkiPassCore` | App and extension (`SkiPassAuthUI` in the app only) |
| Server | `server/` (Hono) | Vercel project `skipass-server` (https://skipass-server.vercel.app) with Upstash Redis; a Cloudflare Workers entry with Workers KV is kept buildable |
| Demo site | `demo-web/` | Vercel project `skipass-demo` (https://skipass-demo.vercel.app), email via Resend |
| Earlier demo site | `demo-site/` | Not deployed; kept for reference, still built and tested in CI |
| CI and packaging | `.github/workflows` | GitHub Actions (`macos-15`, `ubuntu-latest`) |

### SkiPassCore modules

| Module | Responsibility | Used by |
|---|---|---|
| `SkiPassModels` | Shared types (`MailboxConfig`, `FetchedMessage`, `CodeCandidate`, `JudgeOutcome`, `UsageSnapshot`) and protocols (`MailFetching`, `CodeExtracting`, `CandidateJudging`, `UsageReporting`) | Everything |
| `SkiPassStorage` | App Group defaults and Keychain, with the groups resolved at runtime | App, extension |
| `SkiPassMail` | Read-only IMAP fetch on SwiftMail | Extension |
| `SkiPassAuth` | OAuth token refresh (AppAuthCore only, safe for extensions) | App, extension |
| `SkiPassAuthUI` | Interactive Google and Microsoft sign-in (AppAuth) | App only |
| `SkiPassExtraction` | Code extraction (2FHey port) and HTML-to-text | Extension; `SkiPassMail` uses its HTML-to-text |
| `SkiPassServerClient` | HTTP client for `/v1/judge`, `/v1/fills`, `/v1/usage` | App, extension |

The extension links `SkiPassAuth` but never `SkiPassAuthUI`, so no interactive sign-in code runs inside it.

### Identifiers

| Item | Value |
|---|---|
| App bundle ID | `io.github.rkceve.skipass` |
| Extension bundle ID | `io.github.rkceve.skipass.autofill` |
| App Group / Keychain access group | `group.io.github.rkceve.skipass` (resolved at runtime, see section 5) |
| Deployment target | iOS 18.0 |
| Google redirect | `com.googleusercontent.apps.<GOOGLE_CLIENT_ID_PREFIX>:/oauth2redirect` |
| Microsoft redirect | `msauth.io.github.rkceve.skipass://auth` |

A sideloading tool may add a team suffix to the bundle IDs when it re-signs the app. Device IPAs are built in the Debug configuration (see [DECISIONS.md](DECISIONS.md#7-debug-ipa-because-of-the-revenuecat-test-store)) and named `SkiPass-v<MARKETING_VERSION>-b<run>.ipa`.

### Build-time configuration

Values come from `ios/Config/Secrets.xcconfig` (git-ignored; `Secrets.example.xcconfig` is the committed template) and reach the code as Info.plist keys:

| Info.plist key | GitHub Actions secret | Without it |
|---|---|---|
| `SkiPassServerURL` | `SKIPASS_SERVER_URL` | No server: on-device fallback rule, nothing counted |
| `SkiPassAppToken` | `SKIPASS_APP_TOKEN` | Same as above |
| `GoogleClientID` | `GOOGLE_CLIENT_ID` | Google sign-in shows "not configured in this build" |
| `MicrosoftClientID` | `MICROSOFT_CLIENT_ID` | Microsoft sign-in shows "not configured in this build" |
| `RevenueCatAPIKey` | `REVENUECAT_API_KEY` | Plan tab shows "Plans are unavailable in this build." |

Empty values and the template's placeholders are both treated as "not configured".

## 2. App

- Two tabs in a native `TabView`: **Home** (mail accounts) and **Plan**. Liquid Glass is used on controls only (the Add button, the tab bar); content cards are plain.
- **Home** lists the registered addresses. Tapping a card expands it in place.
  - IMAP card: incoming host and port, username, masked password with a reveal button, Edit, Delete.
  - Google or Microsoft card: Delete only (no server settings to show).
- **Add flow**: enter an email address, then Continue.
  - `gmail.com`, `googlemail.com`: Google's official sign-in (AppAuth), with the address pre-filled.
  - Outlook.com consumer domains (outlook, hotmail, live, msn and their country variants): Microsoft's official sign-in. Outlook.com no longer accepts passwords over IMAP.
  - Anything else: an IMAP form (host, port 993 by default, username, password).
  - If the build has no client ID for the provider, an in-app error is shown and the provider page is not opened.
  - Delete asks for confirmation.
- **Plan** shows the current plan (name, tagline, "N of M left", reset date) and the other plans below it. There are no banners or pop-ups. The current plan is the highest active tier. Tapping a paid plan buys its package (RevenueCat Test Store sheet in this build). Upgrades apply at once; a lower paid tier does not replace a higher active one until that one ends. Free opens RevenueCat's manage-subscriptions path. Taps during a purchase are ignored.
- All user-visible strings are in `ios/SkiPassUI/Sources/SkiPassUI/Copy.swift`.
- On launch the app configures RevenueCat with an anonymous app user ID and writes it to the App Group, so the extension sends the same ID to the server.

## 3. AutoFill extension

1. **Request.** `provideCredentialWithoutUserInteraction` receives an `ASOneTimeCodeCredentialRequest`; the service is the identity's service identifier (a domain). Other request types are cancelled with `.credentialIdentityNotFound`.
2. **Fetch.** Load mailboxes and credentials, then fetch INBOX messages received in the last **10 minutes** from all mailboxes **in parallel**, with a **4 s budget per mailbox**. The IMAP fetcher stops 0.4 s before the budget and returns whatever it has read so far. A mailbox that fails contributes nothing. Messages are never marked as read (`EXAMINE`, `BODY.PEEK`).
3. **Extract.** Keep only messages where the extractor finds a code (subject first, then body; HTML is converted to text).
4. **Judge.** Send the full text of those messages to `POST /v1/judge`.
   - A chosen message: fill its code with `completeOneTimeCodeRequest`, then report the fill with `POST /v1/fills` in the background (up to 3 attempts for transient errors).
   - No match or quota exhausted: cancel silently (`.failed`, no UI).
   - Server unreachable, timeout, 5xx, 401, 429, or a reply that names a message that was not sent: use the **local fallback rule** instead, which is the same rule the server uses when Jev fails (newest message that contains the site's registrable domain, else the newest message).
5. **Other entry points.** `prepareOneTimeCodeCredentialList`, `prepareInterfaceToProvideCredential` and `prepareInterfaceForUserChoosingTextToInsert` add no UI of their own: they run the same resolver and complete, or cancel with `.userCanceled`. The last one has no service identifier, so the newest code email is used.
6. **Identity registration.** iOS offers SkiPass only for sites that have a registered `ASOneTimeCodeCredentialIdentity`. The app and the extension register, in the background:
   - a bundled list of about 100 popular sign-in domains (`ios/Extension/Identity/sign-in-domains.json`),
   - the demo site `skipass-demo.vercel.app`,
   - registrable domains found in the sender and links of code emails that were actually filled (mail-provider and click-tracking domains are excluded; at most 100 are kept).

   The label is `From <first mailbox address>`. Registration runs on app launch, when the app comes to the foreground, after a mailbox is added or removed, and when the extension runs. The whole set is replaced each time, and it is emptied when no mailbox is left.

## 4. Server

Hono app in `server/src/api.ts`, with two entries: `app.ts` for Vercel (Upstash Redis) and `src/index.ts` for Cloudflare Workers (Workers KV). Full request and response shapes are in [API.md](API.md).

- **Auth.** `X-SkiPass-App-Token` must equal `APP_TOKEN`, else 401. `X-SkiPass-User` is the RevenueCat app user ID.
- **Known users only.** An ID that RevenueCat does not know gets 401 `unknown_user` on every route, before Jev is called or anything is counted. A confirmed user is not checked again for 10 minutes.
- **Rate limit.** `/v1/judge` allows 60 requests per user and 300 per client IP per UTC hour (429).
- **`POST /v1/judge`** does not count usage. The quota check (402 when used >= limit) runs concurrently with Jev. One Noul question per message, in parallel, 3 s timeout. The highest score of at least 0.5 wins, ties go to the newest `Date:`, and none above 0.5 gives `chosenId: null`. Any Jev failure switches to the fallback rule with `source: "fallback"`.
- **`POST /v1/fills`** checks the limit and increments `usage:<user>:<YYYY-MM>` (UTC month) in one atomic step (a Lua `EVAL` on Redis); 402 at the limit.
- **`GET /v1/usage`** returns the plan, used, limit and `resetsAt` (start of the next UTC month).
- **Plans.** The plan is the highest active entitlement (`pro`, then `standard`) from the RevenueCat REST API v2, else Free. Limits are Free 10, Standard 100, Pro 1,000 fills per month, in `server/src/plans.ts` (still marked provisional there).
- **RevenueCat outage.** Each successful lookup stores the user's plan for 30 days. If RevenueCat fails, that plan is used; with none stored, the quota is not enforced for the request and `/v1/usage` answers `plan: "unknown"`, `limit: 0`. A paying user is never downgraded because RevenueCat is down.
- **Mock modes.** `JEV_MODE=mock` uses a deterministic stand-in (`source: "mock"`); `REVENUECAT_MODE=mock` treats every user as a known Free user. Live mode without its key is logged as a configuration error: Jev falls back to the rule, RevenueCat is treated as an outage.
- **Registrable domains** use the Public Suffix List including its private section (tldts, `allowPrivateDomains: true`), so `skipass-demo.vercel.app` is not reduced to `vercel.app`. The extension's local rule uses a bundled two-label suffix table generated from the same tldts version, with a parity test.
- **No content logging.** Email text and metadata are never logged or stored. The only stored data are fill counters, rate-limit counters and each user's last known plan.

## 5. Storage and security on the device

- **App Group defaults** (`group.io.github.rkceve.skipass`):

  | Key | Content |
  |---|---|
  | `mailboxes.v1` | JSON list of `MailboxConfig` (no secrets) |
  | `rc.appUserID` | RevenueCat app user ID, written by the app, read by the extension |
  | `usage.snapshot.v1` | Last known usage, for the Plan screen |
  | `identity.seenDomains.v1` | Domains of filled code emails, newest first |

- **Keychain** generic passwords, service `io.github.rkceve.skipass`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable:
  - `password.<mailboxID>`: the IMAP password;
  - `oauth.<mailboxID>`: the archived AppAuth `OIDAuthState` (refresh token).
- The App Group and Keychain group are **resolved at runtime**, so app and extension still share them after a sideloading tool re-signs the app with another team. If sharing is not possible, the app keeps working on its own and both processes log the groups they resolved.
- **IMAP transport**: implicit TLS on port 993, STARTTLS on any other port, never plaintext. Google and Microsoft accounts authenticate with XOAUTH2 using a fresh access token.
- **Secrets** are never committed. Public client keys (Google client ID, RevenueCat Test Store key) come from GitHub Actions secrets at build time; server keys are Vercel environment variables.

## 6. Demo site

A mobile-first sign-up page for "Sowbank", a fictional neighbourhood seed library:

- Enter an email address; `/api/send-code` sends the code with Resend (subject `<code> is your Sowbank verification code`, body contains the code and `https://skipass-demo.vercel.app`).
- `/verify` has an `autocomplete="one-time-code"` 6-digit field; six digits entered at once are checked immediately.
- 30 s resend cooldown, 10-minute expiry, locked after 5 wrong attempts. The browser holds only a random session ID in an HttpOnly cookie; the hashed code and counters live in Upstash Redis.
- With Resend's sandbox sender only the account owner's address receives mail; other addresses get a clear 403 message.

Details: [demo-web/README.md](../demo-web/README.md).

## 7. Quality checks

The `ci` workflow must pass: SkiPassCore tests, SkiPassUI package tests, app build with app tests, extension tests, server tests and typecheck (plus a Worker bundle dry run), demo site tests and typecheck. The UI tour recording is informational and not a gate.

## 8. Accepted trade-offs

- When the server is unreachable (timeout, 5xx, 401, 429, bad reply) the extension fills with the local fallback rule and without a quota check; the fill is reported later if possible. Quota enforcement is therefore best-effort, in favour of filling reliably.
- A fill is counted after it happens, so two fills at the same moment can pass the same quota check.
- The app token is embedded in the app and is public by nature. Abuse is limited by rejecting unknown RevenueCat customers and by the `/v1/judge` rate limits.
- If RevenueCat is down, the server uses the last known plan (and does not enforce a quota when none is known) rather than downgrading a paying user.
- Keychain sharing between app and extension after re-signing can only be verified on a device; both processes log the resolved App Group and Keychain group.
- With several mailboxes, identities are labelled with the first address only.
