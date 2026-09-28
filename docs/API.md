# Server HTTP API

The SkiPass server (`server/src/api.ts`) has three routes. The Swift client is `SkiPassServerClient` (`ios/SkiPassCore/Sources/SkiPassServerClient/ServerClient.swift`).

Production base URL: `https://skipass-server.vercel.app`. Local: `http://localhost:8787` (`npm run dev` in `server/`).

## Common rules

### Headers

| Header | Value |
|---|---|
| `Content-Type` | `application/json` (requests with a body) |
| `X-SkiPass-App-Token` | Must equal the server's `APP_TOKEN` (the app's `SkiPassAppToken`) |
| `X-SkiPass-User` | RevenueCat app user ID (at most 256 characters) |

When the extension has no app user ID yet (the app has not run), it sends `X-SkiPass-User: anonymous` on `/v1/judge` only, and does not report fills.

### Errors on every route

| Status | Body | When |
|---|---|---|
| 401 | `{"error":"unauthorized"}` | `X-SkiPass-App-Token` missing or wrong, or the server has no `APP_TOKEN` |
| 400 | `{"error":"invalid_request"}` | `X-SkiPass-User` missing, empty or too long; malformed body |
| 401 | `{"error":"unknown_user"}` | RevenueCat does not know `X-SkiPass-User` (live RevenueCat mode only). A confirmed user is cached for 10 minutes |
| 500 | not JSON | Vercel deployment without the Upstash Redis store; counters are never silently zero |

Checks run in this order: app token and user header, then (on `/v1/judge`) the rate limit, then the known-user check. Jev is never called and nothing is counted for a rejected request.

### How the iOS client treats errors

| Response | Extension behaviour |
|---|---|
| 200 with a `chosenId` that was sent | Fill that code |
| 200 with `chosenId: null` | Cancel silently |
| 402 `quota_exhausted` | Cancel silently |
| 401 (either kind), 429, 5xx, timeout, bad JSON, or a `chosenId` that was not sent | On-device fallback rule, then fill |

Fill reports are retried up to 3 times for transient errors (timeouts, 408, 429, 5xx, network errors) and never block the fill.

## `POST /v1/judge`

Chooses which email holds the code for `service`. Does **not** count usage.

Request:

```json
{
  "service": "acme.example.com",
  "messages": [
    { "id": "3F2A...:inbox:123", "text": "From: ...\nTo: ...\nSubject: ...\nDate: 2026-09-27T09:59:00Z\n\n<body text>" }
  ]
}
```

| Field | Rules |
|---|---|
| `service` | Site domain or `null` (no site known). An empty string is treated as `null` |
| `messages` | 1 to 50 items |
| `messages[].id` | Unique, non-empty, at most 512 characters. The app uses `<mailboxID>:<folder>:<IMAP UID>`, with folder `inbox` or `junk` (UIDs are only unique within one folder) |
| `messages[].text` | At most 200,000 characters: header lines `From`, `To`, `Subject`, `Date` (ISO 8601), a blank line, then the body as plain text |

Response 200:

```json
{ "chosenId": "3F2A...:123", "scores": { "3F2A...:123": 0.97 }, "remaining": 42, "source": "jev" }
```

| Field | Meaning |
|---|---|
| `chosenId` | The chosen message, or `null` when no message scored at least 0.5 |
| `scores` | Noul score per message id; empty when the fallback rule was used |
| `remaining` | Fills left this month. `0` also means "not known" when RevenueCat is unavailable and no plan is cached, so clients must not show it as a count on its own |
| `source` | `"jev"`: scored by Jev. `"fallback"`: Jev failed, timed out or is not configured, and the fallback rule chose. `"mock"`: server runs with `JEV_MODE=mock` |

Other responses:

| Status | Body | When |
|---|---|---|
| 402 | `{"error":"quota_exhausted","remaining":0}` | The user's fills this month are at or above the plan's limit |
| 429 | `{"error":"rate_limited"}` | More than 60 requests from this user or 300 from this client IP in the current UTC hour |

### Selection

- One Jev question per message, all in parallel, 3 s timeout each, run concurrently with the plan lookup.
- The highest score of at least 0.5 wins; on a tie the newest `Date:` wins; no score at 0.5 or above gives `chosenId: null`.
- If any Jev call fails, the whole request uses the **fallback rule**: the newest message whose text contains the service's registrable domain, else the newest message; `source: "fallback"`.
- Registrable domains follow the Public Suffix List including private suffixes (`skipass-demo.vercel.app` stays as is).

### Jev request (server to TypeSafe)

`POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <JEV_API_KEY>`:

```json
{
  "state": "<message text>",
  "model": "jev-latest",
  "questions": {
    "is_code_for_service": {
      "type": "noul",
      "instructions": "A user is signing in on the website <service> and needs the one-time code that this website just emailed them. Is this email that code email from <service> (the sender may use a different brand name or email provider, but the email mentions or links to <service>)?",
      "criteria": {
        "true": "A one-time verification code email sent by or for <service>",
        "false": "A code email from a different website, a promotional email, or an email without a one-time code"
      }
    }
  }
}
```

With `service: null` the instructions are `Is this email delivering a one-time verification or sign-in code?` and there are no criteria. The score is read from `answers.is_code_for_service.noul` and must be a number from 0 to 1.

## `POST /v1/fills`

Counts exactly one fill. Called by the extension after iOS accepted the code.

Request:

```json
{ "messageId": "3F2A...:inbox:123" }
```

| Status | Body | When |
|---|---|---|
| 200 | `{"remaining":41}` | Counted |
| 402 | `{"error":"quota_exhausted","remaining":0}` | Already at the limit; nothing counted |

The limit check and the increment are one atomic step (a Lua `EVAL` on Redis). The key is `usage:<appUserID>:<YYYY-MM>` in UTC. When no plan is known (RevenueCat unavailable and nothing cached), the fill is counted without a limit and `remaining` is `0` ("not known").

## `GET /v1/usage`

Response 200:

```json
{ "plan": "standard", "used": 3, "limit": 100, "resetsAt": "2026-10-01T00:00:00Z" }
```

| Field | Meaning |
|---|---|
| `plan` | `"free"`, `"standard"`, `"pro"`, or `"unknown"` (RevenueCat unavailable and no cached plan; `limit` is then `0`) |
| `used` | Fills counted this UTC month |
| `limit` | Monthly fill limit of the plan |
| `resetsAt` | Start of the next UTC month |

## Plans

| Plan | RevenueCat entitlement (lookup key) | Fills per month |
|---|---|---|
| `free` | none | 10 |
| `standard` | `standard` | 100 |
| `pro` | `pro` | 1,000 |

Defined in `server/src/plans.ts`. The plan is the highest active entitlement from RevenueCat REST API v2 (`GET /v2/projects/{project_id}/customers/{id}/active_entitlements`, with entitlement IDs mapped to lookup keys through `GET /v2/projects/{project_id}/entitlements`, cached for 10 minutes). Each successful lookup stores the plan for 30 days as the fallback during a RevenueCat outage.

## Server configuration

| Name | Kind | Notes |
|---|---|---|
| `APP_TOKEN` | secret | Unset means every request is 401 |
| `JEV_MODE` | variable | `mock` for the deterministic stand-in (domain or brand word in the text scores 0.9, else 0.1); anything else is live |
| `JEV_API_KEY` | secret | Live without it: logged configuration error, every judge uses the fallback rule |
| `REVENUECAT_MODE` | variable | `mock`: every user is a known Free user; anything else is live |
| `REVENUECAT_SECRET_KEY` | secret | RevenueCat API v2 secret key with `customer_information:customers:read` and `project_configuration:entitlements:read` |
| `REVENUECAT_PROJECT_ID` | variable | RevenueCat project ID |
| `KV_REST_API_URL`, `KV_REST_API_TOKEN` | Vercel | Upstash Redis REST credentials (`UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` also accepted) |
| `USAGE` | Workers KV binding | Cloudflare entry only |

On Vercel the client IP for the rate limit comes from `x-vercel-forwarded-for`, then `x-real-ip`, then the first `x-forwarded-for` entry; on Cloudflare from `CF-Connecting-IP`.
