# Design decisions

Short records of the main choices, why they were made, and what they cost.

## 1. AutoFill Credential Provider one-time-code API, not a custom keyboard

**Context.** The code has to reach a verification-code field in any app or website with as little effort as possible.

**Decision.** Use the one-time-code support of the AutoFill Credential Provider extension (`ASOneTimeCodeCredentialIdentity`, `ASOneTimeCodeCredentialRequest`, iOS 18+). iOS shows SkiPass as a suggestion above the normal keyboard in fields marked as one-time-code fields, and the extension runs only when that suggestion is tapped.

**Why not a custom keyboard.** A keyboard extension would replace the user's keyboard for everything they type and would need "Allow Full Access" to use the network, which is a lot of trust to ask of a tool that reads mail. The credential provider keeps the system keyboard, runs only on demand, and is the path iOS offers for exactly this job.

**Consequences.**
- iOS decides when and how the suggestion is shown. The extension can set only the subtitle (`From <mailbox>`), and a suggestion appears only for domains registered in advance (see identity registration in [ARCHITECTURE.md](ARCHITECTURE.md#3-autofill-extension)).
- Requires iOS 18. iOS 18 also calls `prepareInterfaceForUserChoosingTextToInsert` for some fields; SkiPass implements it with the same resolver, because without it iOS can show an "AutoFill Unavailable" error.

## 2. IMAP for every provider, with OAuth (XOAUTH2) for Gmail and Outlook.com

**Context.** Users have Gmail, Outlook.com and custom-domain mailboxes.

**Decision.** Read every mailbox over IMAP with one fetcher (SwiftMail). Gmail and Outlook.com sign in through their official OAuth pages (AppAuth) and authenticate to IMAP with XOAUTH2; other providers use an IMAP password. Outlook.com no longer accepts passwords over IMAP, so OAuth is required there.

**Why.** One protocol and one code path for all providers, one test suite, and the same read-only guarantees everywhere: INBOX is opened with `EXAMINE` and bodies are fetched with `BODY.PEEK`, so nothing is ever marked as read.

**Consequences.**
- Google's full-mail scope (`https://mail.google.com/`) is a restricted scope; a public release would need Google's OAuth app verification.
- The extension refreshes OAuth tokens itself with AppAuthCore; interactive sign-in stays in the app (`SkiPassAuthUI`), so the extension never links UI sign-in code.

## 3. Code extraction on the device

**Context.** Most recent emails contain no code, and email is sensitive.

**Decision.** Extract codes in the extension with a Swift port of the open-source 2FHey parser (CC0) and its pattern files, plus SkiPass additions (email-specific guards against promotional and order numbers, full-width digits, Japanese patterns). The subject is checked first, then the body; HTML is converted to text.

**Why.** Only emails that contain a code ever leave the device, and the server never sees the rest of the inbox. Extraction needs no network and adds no latency. The upstream feature that downloads updated patterns at runtime was removed: an AutoFill extension should not fetch code or rules while filling.

**Consequences.** New code formats need an app update to be recognised.

## 4. Jev: one yes/no question per email, judged against the requesting site

**Context.** "Newest email with a code" picks the wrong one when two sites send codes, a code is resent, or a newsletter contains a number. Sender-domain matching fails when a service sends from a mail provider or under a different brand name.

**Decision.** The server asks Jev (TypeSafe System One) a separate Noul question for each candidate email: is this the code email from `<site>`? The highest score of at least 0.5 wins, ties go to the newest email, and no score above 0.5 means no fill.

**Why.**
- Each email is judged on its own, so the questions run in parallel within a 3 s timeout, and one noisy email cannot distort the others.
- A fixed threshold gives a clear "none of these" answer, which is safer than always filling something.
- The wording was tuned by a live comparison recorded in `server/src/jev.ts`: the correct email scored 0.87 against 0.65 with the first wording, while other sites' code emails and promotions stayed at 0.01 to 0.02.

**Consequences.** Candidate emails are sent to a third-party API at fill time (only emails from the last 10 minutes that contain a code). Latency and availability depend on Jev, which is why decision 5 exists.

## 5. Local fallback when the server is unavailable

**Context.** A fill that silently fails because of a network problem is worse than a slightly less careful fill.

**Decision.** When the server cannot answer (timeout, 5xx, 401, 429, malformed reply), the extension applies the same deterministic rule the server uses when Jev fails: the newest email that mentions the site's registrable domain, else the newest email. A valid server answer, including "no match" and "quota exhausted", is final.

**Trade-off.** Filling keeps working with the server down, but quota enforcement becomes best-effort: fallback fills skip the quota check and are reported later if possible. Fills are also counted after they happen, so two simultaneous fills can pass the same check. For a small per-fill product this was judged acceptable; strict metering would need a reservation step before every fill.

**Consistency.** The server uses tldts with the Public Suffix List's private section; the extension uses a bundled two-label suffix table generated from the same tldts version, and a parity test keeps both rules in agreement on the bundled cases.

## 6. Stateless server with an Upstash Redis counter

**Context.** The server needs to know a user's plan and count fills, and nothing else.

**Decision.** No user accounts and no email storage. The RevenueCat app user ID is the identity, RevenueCat's REST API v2 is the source of truth for the plan, and Upstash Redis holds only per-user monthly fill counters, hourly rate-limit counters and each user's last known plan. The server is one Hono app deployed on Vercel.

**Why.**
- Serverless functions keep no memory between requests, so the counter needs an external store. Redis runs "check the limit and increment" as one Lua `EVAL`, which is atomic; Cloudflare Workers KV (the other supported entry) has no atomic increment.
- Keeping only counters means there is no email data to leak, and the privacy claim "never stored or logged" is easy to check in the code.

**Consequences.** Every request looks up the plan with RevenueCat (only the known-user check is cached, for 10 minutes). If RevenueCat is down, the last known plan is used, and with none known the quota is not enforced, so a paying user is never downgraded by an outage.

## 7. Debug IPA because of the RevenueCat Test Store

**Context.** The hackathon build uses the RevenueCat Test Store, so purchases can be demonstrated without App Store Connect products or real payments.

**Decision.** Device IPAs are always built in the Debug configuration.

**Why.** `purchases-ios` deliberately stops a Release build that is configured with a Test Store API key, to prevent shipping one by accident.

**Consequences.** The IPA is a Debug build. Test Store subscriptions cannot be cancelled from the app; they end by themselves. A store release would switch to a platform API key and a Release build.

## 8. Built and sideloaded without a Mac

**Context.** The project was developed on Windows, and the Next Gen category does not require a paid Apple developer account or a store release.

**Decision.**
- The Xcode project is generated from `project.yml` with XcodeGen, so no `.xcodeproj` is committed.
- GitHub Actions macOS runners compile and test all Swift code (`ci`), build an ad-hoc signed device IPA (`ipa`), record a UI tour (`tour`) and can stream an interactive Simulator to a browser (`live-sim`).
- The IPA is installed with a sideloading tool that re-signs it with a free Apple ID.

**Consequences.**
- Free-account installs must be re-signed every 7 days.
- Re-signing can change the team prefix and bundle IDs, so the App Group and Keychain group are resolved at runtime rather than hard-coded, and both processes log what they resolved.
- The IPA embeds the app token, so IPA artifacts in this public repository are kept for 3 days only.
- Anyone can reproduce the build from a fork with the same workflows.
