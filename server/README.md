# SkiPass server (Hono — Vercel and Cloudflare Workers)

Implements `docs/CONTRACTS.md` §5: `POST /v1/judge`, `POST /v1/fills`, `GET /v1/usage`.
One Hono app (`src/api.ts`) with two entry points:

| Target | Entry | Usage counter | URL |
|---|---|---|---|
| Vercel (production) | `app.ts` → `src/vercel.ts` | Upstash Redis (atomic `INCR`) | https://skipass-server.vercel.app |
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
| `JEV_MODE` | var | `live` or `mock`; mock is also used when `JEV_API_KEY` is empty |
| `JEV_API_KEY` | secret | TypeSafe API key |
| `REVENUECAT_MODE` | var | `live` (default) or `mock` (always plan `free`); mock is also used when the key or project id is empty |
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

- Workers KV has no atomic increment: two concurrent `/v1/fills` for the same user can be counted once
  (Redis on Vercel counts both: `INCR`, and `DECR` back when over the limit).
- KV is eventually consistent across locations: a count written in one location may take time to be visible in another.
- No request logging: message text and metadata are never logged or stored.
