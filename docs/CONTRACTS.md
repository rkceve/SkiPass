# CONTRACTS — interfaces every agent must follow

Owner: orchestrator. Agents never edit this file; if a contract is wrong or missing, stop and report.
Product decisions live in `SPEC_v2.md` (kept outside the repo). Facts with sources live in `docs/facts/F1..F3`.

## 0. Global rules

- Do not implement anything the spec marks [Open]. Leave `// OPEN(<area>): <what>` and report it.
- No imagined APIs. Every external API call (Apple, SwiftMail, AppAuth, RevenueCat, Jev, Cloudflare, Hono) must be backed by `docs/facts/*` or a doc/source URL you read; list them in your report. Unconfirmed = `UNVERIFIED` in report.
- Test fixtures are derived from real samples (docs, real message formats), not invented shapes.
- Touch only the paths you own (§1). Never commit to `main`. Never print secrets.
- Code, comments, identifiers: English.

## 1. Repository layout and ownership

| Path | Owner |
|---|---|
| `project.yml`, `ios/Config/`, `.github/workflows/`, `ios/UITests/`, `ios/Probe/` | I1 Scaffold & CI |
| `ios/SkiPassCore/Package.swift`, `ios/SkiPassCore/Sources/SkiPassModels/` | orchestrator (fixed; request changes) |
| `ios/SkiPassCore/Sources/SkiPassStorage/`, `.../SkiPassMail/`, `.../SkiPassAuth/`, `.../SkiPassAuthUI/` (+ their Tests) | I2 Mail & Auth |
| `ios/SkiPassCore/Sources/SkiPassExtraction/` (+ Tests) | I3 Extraction |
| `ios/SkiPassCore/Sources/SkiPassServerClient/` (+ Tests), `server/` | I5 Server |
| `ios/Extension/` | I4 Extension |
| `ios/SkiPassUI/` | I6 UI (done, round 1) |
| `ios/App/` | I6 App wiring |
| `demo-site/` | I7 Demo site (blocked: Open) |
| `eval/` | I8 Evaluation |
| `docs/`, `README.md` | orchestrator |

## 2. Identifiers and build settings

| Item | Value |
|---|---|
| App bundle ID | `io.github.rkceve.skipass` |
| Extension bundle ID | `io.github.rkceve.skipass.autofill` |
| UI test bundle ID | `io.github.rkceve.skipass.uitests` |
| App Group | `group.io.github.rkceve.skipass` |
| Keychain access group | same string as the App Group (`group.io.github.rkceve.skipass`), so no team prefix is needed |
| Deployment target | iOS 18.0 (app, extension, packages) |
| CI | GitHub Actions `macos-15`, Xcode 26.x (newest installed), simulator **iPhone 16**, newest iOS 26.x runtime (iPhone 16 screenshots are 1179×2556) |
| Signing | Simulator only; no team; entitlements files still declared |
| Google redirect | `com.googleusercontent.apps.<GOOGLE_CLIENT_ID_PREFIX>:/oauth2redirect` |
| Microsoft redirect | `msauth.io.github.rkceve.skipass://auth` |

Build-time configuration comes from `ios/Config/Secrets.xcconfig` (git-ignored; `ios/Config/Secrets.example.xcconfig` committed) and is exposed through Info.plist keys:
`SkiPassServerURL`, `SkiPassAppToken`, `GoogleClientID`, `MicrosoftClientID`, `RevenueCatAPIKey`.
In CI these come from GitHub secrets of the same names in SCREAMING_SNAKE_CASE (`SKIPASS_SERVER_URL`, `SKIPASS_APP_TOKEN`, `GOOGLE_CLIENT_ID`, `MICROSOFT_CLIENT_ID`, `REVENUECAT_API_KEY`), plus test-only `DEMO_MAILBOX_ADDRESS`, `DEMO_GOOGLE_REFRESH_TOKEN`.

## 3. Shared Swift models (`SkiPassModels`, fixed)

See `ios/SkiPassCore/Sources/SkiPassModels/*.swift`. Summary:
- `ProviderKind` (`google`, `microsoft`, `imap`) with IMAP presets: google `imap.gmail.com:993`, microsoft `outlook.office365.com:993`.
- `MailboxConfig` — persisted mailbox (no secrets).
- `FetchedMessage` — one email as text: `id` = `"<mailboxID>:<uid>"`, `mailboxAddress`, `from`, `to`, `subject`, `date`, `bodyText` (plain text; HTML converted by I3's `HTMLText`).
- `CodeCandidate` — message + extracted code.
- Protocols: `MailFetching`, `CodeExtracting`, `CandidateJudging`, `UsageReporting`.
- `JudgeOutcome` — `.chosen(messageID, scores)`, `.noMatch(scores)`, `.quotaExhausted`.

## 4. Shared storage (implemented by I2 in `SkiPassStorage`)

- App Group `UserDefaults(suiteName: "group.io.github.rkceve.skipass")`:
  - `mailboxes.v1` → JSON `[MailboxConfig]`
  - `rc.appUserID` → String (written by app after RevenueCat configure; read by extension)
  - `usage.snapshot.v1` → JSON `UsageSnapshot` (last known usage, for the app UI)
- Keychain generic passwords: service `io.github.rkceve.skipass`, access group = App Group, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable.
  - account `password.<mailboxID>` → UTF-8 IMAP password
  - account `oauth.<mailboxID>` → `NSKeyedArchiver` data of AppAuth `OIDAuthState`

## 5. Server HTTP API (Cloudflare Worker, implemented by I5; Swift client in `SkiPassServerClient`)

All requests: `Content-Type: application/json`, headers `X-SkiPass-App-Token: <SkiPassAppToken>`, `X-SkiPass-User: <RevenueCat app user ID>`. Missing/invalid token → 401 `{"error":"unauthorized"}`.

`POST /v1/judge` — does NOT count usage.
```json
request:  {"service": "acme.example.com" | null,
           "messages": [{"id": "uuid:123", "text": "From: ...\nTo: ...\nSubject: ...\nDate: ...\n\n<body text>"}]}
200:      {"chosenId": "uuid:123" | null, "scores": {"uuid:123": 0.97}, "remaining": 42, "source": "jev" | "fallback"}
402:      {"error": "quota_exhausted", "remaining": 0}
```
`POST /v1/fills` — counts exactly one fill.
```json
request:  {"messageId": "uuid:123"}
200:      {"remaining": 41}
402:      {"error": "quota_exhausted", "remaining": 0}
```
`GET /v1/usage`
```json
200:      {"plan": "free" | "standard" | "pro", "used": 3, "limit": 10, "resetsAt": "2026-10-01T00:00:00Z"}
```
Jev call (per message, in parallel; `POST https://api.typesafe.ai/v1/systemone`, `model: "jev-latest"`, one Noul question id `is_code_for_service`):
- state: the message `text` (full message, decided).
- instructions (service known): `A user is signing in on the website <service> and needs the one-time code that this website just emailed them. Is this email that code email from <service> (the sender may use a different brand name or email provider, but the email mentions or links to <service>)?`
  criteria.true: `A one-time verification code email sent by or for <service>` / criteria.false: `A code email from a different website, a promotional email, or an email without a one-time code`.
- instructions (service null): `Is this email delivering a one-time verification or sign-in code?`
- Choose the highest `noul` ≥ 0.5; ties → newest `Date`. None ≥ 0.5 → `chosenId: null`.
- Jev failure/timeout (3 s) → fallback: newest message whose text contains the service's registrable domain, else newest message; `source: "fallback"`.
Plans/limits/entitlement IDs: values are [Open]; keep them in one `server/src/plans.ts` table.
Mock modes (env): `JEV_MODE=mock`, `REVENUECAT_MODE=mock`.
Worker secrets: `JEV_API_KEY`, `REVENUECAT_SECRET_KEY`, `APP_TOKEN`. KV namespace binding: `USAGE`, key `usage:<appUserID>:<YYYY-MM>`.

## 6. Extension flow (I4)

1. `provideCredentialWithoutUserInteraction(for:)` with `ASOneTimeCodeCredentialRequest` → service = identity.serviceIdentifier.identifier.
2. Load mailboxes + credentials (SkiPassStorage); fetch messages from the last 10 minutes from every mailbox in parallel (`MailFetching`), 4 s budget per mailbox.
3. Keep messages where `CodeExtracting` finds a code.
4. `CandidateJudging.judge(service:messages:)`:
   - `.chosen` → `completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code:))`, then `UsageReporting.reportFill(messageID:)` (fire-and-forget).
   - `.quotaExhausted` / `.noMatch` / errors → `cancelRequest(withError: ASExtensionError(.failed))`. Nothing is shown (decided: silent).
5. Identity registration (`ASOneTimeCodeCredentialIdentity`, label `From <mailbox address>`): source of domains and multi-mailbox labelling are [Open] — implement behind `IdentityDomainSource` protocol with no concrete source yet.

## 7. CI helper

Agents with CI duties read runs/logs through the GitHub REST API using the token from `git credential fill` (host github.com). Never echo the token. Push only to your own branch `wip/<agent-id>`.

## 8. Change log

- 2026-09-24: `SkiPassAuth` now depends on `SkiPassMail` + `AppAuthCore` only (extension-safe); new `SkiPassAuthUI` (app only, `AppAuth`) for interactive sign-in; new `SkiPassAuthTests`. The extension links `SkiPassAuth`, never `SkiPassAuthUI`.
- 2026-09-27: Jev question wording updated after a live comparison (correct email 0.65 -> 0.87); upstream timeout 2 s -> 3 s; Jev live on Vercel.
