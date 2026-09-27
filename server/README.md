# SkiPass server (Hono — Vercel and Cloudflare Workers)

Implements `docs/CONTRACTS.md` §5: `POST /v1/judge`, `POST /v1/fills`, `GET /v1/usage`.

Abuse and outage rules (docs/SYSTEM.md):

- The app token is public (it ships in every IPA). Every `/v1/*` request therefore also needs an
  `X-SkiPass-User` that RevenueCat knows: a 404 from `active_entitlements` (while the project's
  entitlement list loads) is 401 `{"error":"unknown_user"}`. A confirmed user is trusted for 10 min.
- `/v1/judge` is limited to 60 requests per user and 300 per client IP per UTC hour -> 429
  `{"error":"rate_limited"}` (one atomic Lua `EVAL` on Redis).
- Each successful RevenueCat lookup stores the plan under `plan:<appUserID>` for 30 days. When
  RevenueCat fails or times out, that plan is used; with nothing stored the quota is not enforced for
  the request and `/v1/usage` reports `plan: "unknown"`, `limit: 0`. A paying user is never downgraded.
- Mock modes only when `JEV_MODE=mock` / `REVENUECAT_MODE=mock`. Live without its key is a config
  error logged once per instance (`config error: ...`, names only): Jev -> fallback rule with
  `source: "fallback"`, RevenueCat -> as an outage. Mock judging reports `source: "mock"`.
- Registrable domains use the Public Suffix List with its private section (tldts
  `allowPrivateDomains: true`), so `skipass-demo.vercel.app` is not collapsed to `vercel.app`.
One Hono app (`src/api.ts`) with two entry points:

| Target | Entry | Usage counter | URL |
|---|---|---|---|
| Vercel (production) | `app.ts` → `src/vercel.ts` | Upstash Redis (atomic Lua `EVAL`, 2 s timeout) | https://skipass-server.vercel.app |
| Cloudflare Workers | `src/index.ts` | Workers KV `USAGE` | `https://skipass-server.<subdomain>.workers.dev` |

The Worker side was scaffolded from Hono's `cloudflare-workers` template
(https://github.com/honojs/starter/tree/main/templates/cloudflare-workers). The Vercel side follows
https://vercel.com/docs/frameworks/backend/hono and https://hono.dev/docs/getting-started/vercel
(default-exported Hono app in a file that imports `hono`).

## Local

```sh
npm install
cp .dev.vars.example .dev.vars   # git-ignored; mock modes, APP_TOKEN=dev-app-token
npm run dev                      # Worker at http://localhost:8787
npm test                         # vitest + @cloudflare/vitest-plugin (workerd); covers both targets
npm run typecheck
```

## Configuration

| Name | Kind | Notes |
|---|---|---|
| `APP_TOKEN` | secret | must equal the app's `SkiPassAppToken`; unset = every request is 401 |
| `JEV_MODE` | var | `mock` for the stand-in; anything else is live (live without `JEV_API_KEY` = logged config error, fallback rule) |
| `JEV_API_KEY` | secret | TypeSafe API key |
| `REVENUECAT_MODE` | var | `mock` (always plan `free`, everyone known); anything else is live (live without key or project id = logged config error, treated as an outage) |
| `REVENUECAT_SECRET_KEY` | secret | RevenueCat **API v2** secret key (`sk_…`, needs `customer_information:customers:read` and `project_configuration:entitlements:read`) |
| `REVENUECAT_PROJECT_ID` | var | RevenueCat project id (`projc9e01f04`) |
| `KV_REST_API_URL` / `KV_REST_API_TOKEN` | Vercel env | Upstash Redis REST credentials, set by the Vercel Marketplace integration (`UPSTASH_REDIS_REST_URL` / `UPSTASH_REDIS_REST_TOKEN` are also accepted) |
| `USAGE` | Worker KV binding | key `usage:<appUserID>:<YYYY-MM>` (UTC) — the Redis key is the same |

Plans, entitlement lookup keys and limits live only in `src/plans.ts` (placeholder values, OPEN).
The plan comes from RevenueCat API v2 `GET /v2/projects/{project_id}/customers/{id}/active_entitlements`;
active entitlement ids (`entl…`) are mapped to lookup keys via `GET /v2/projects/{project_id}/entitlements`
(cached 10 min per instance). API v1 `/v1/subscribers` rejects v2 keys (HTTP 403, code 7723).

## Deploy — Vercel (project `skipass-server`)

```sh
npx vercel link --yes --project skipass-server
npx vercel env add APP_TOKEN production --sensitive
npx vercel env add REVENUECAT_SECRET_KEY production --sensitive
npx vercel env add REVENUECAT_PROJECT_ID production
npx vercel env add JEV_MODE production        # "mock" until a Jev key exists
npx vercel deploy --prod
```

Storage: Vercel dashboard → project `skipass-server` → Storage → Upstash (Redis) → Create/Connect
(adds `KV_REST_API_URL` / `KV_REST_API_TOKEN`), then redeploy. Without it `/v1/judge`, `/v1/fills`
and `/v1/usage` answer 500 (the counter is never silently zero).

Vercel notes: `vercel.json` pins the Hono framework preset; `.vercelignore` keeps `src/index.ts` out
of the upload because Vercel picked a `src/` candidate (`src/app.ts`, before its rename to `src/api.ts`) over the
root `app.ts`; relative imports carry a
`.js` extension because Vercel runs the compiled files as plain Node ESM.

## Deploy — Cloudflare Workers

```sh
npx wrangler login
npx wrangler kv namespace create USAGE        # paste the printed id into wrangler.jsonc "kv_namespaces"[0].id
npx wrangler secret put APP_TOKEN
npx wrangler secret put JEV_API_KEY
npx wrangler secret put REVENUECAT_SECRET_KEY
npm run deploy                                # wrangler deploy --minify
```

The deployed URL goes into `SkiPassServerURL` (`ios/Config/Secrets.xcconfig`, CI secret
`SKIPASS_SERVER_URL`); the same `APP_TOKEN` value goes into `SkiPassAppToken` / `SKIPASS_APP_TOKEN`.

## Known limits

- Workers KV has no atomic increment: two concurrent `/v1/fills` (or judge rate-limit hits) for the same
  user can be counted once. Redis on Vercel checks and counts in one Lua `EVAL` (atomic, no compensation).
- KV is eventually consistent across locations: a count written in one location may take time to be visible in another.
- No request logging: message text and metadata are never logged or stored.
