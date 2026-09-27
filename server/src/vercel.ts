// Vercel target: the same Hono app as the Worker (src/api.ts), with Vercel environment variables
// as its bindings and the usage counter in Upstash Redis (Vercel Marketplace integration).
//
// Vercel runs a Hono app from the default export of a file at a fixed location
// (https://vercel.com/docs/frameworks/backend/hono, "Exporting the Hono application";
// https://hono.dev/docs/getting-started/vercel: "export the Hono application as a default export").
// That file is `app.ts` at the package root; it calls `createVercelApp(process.env)`.
// On Vercel, bindings do not arrive through `c.env`, so the outer app forwards every request to
// the inner app with the bindings passed explicitly (`app.fetch(request, env)`).

import { Hono } from 'hono'
import { createApp } from './api.js'
import type { Bindings, Deps } from './env.js'
import { RedisUsageCounter, redisConfigFromEnv } from './usage.js'

export type VercelEnv = Record<string, string | undefined>

/** Picks the bindings the app reads from a Vercel (process) environment. */
export function bindingsFromEnv(env: VercelEnv): Bindings {
  return {
    APP_TOKEN: env.APP_TOKEN,
    JEV_MODE: env.JEV_MODE,
    JEV_API_KEY: env.JEV_API_KEY,
    REVENUECAT_MODE: env.REVENUECAT_MODE,
    REVENUECAT_SECRET_KEY: env.REVENUECAT_SECRET_KEY,
    REVENUECAT_PROJECT_ID: env.REVENUECAT_PROJECT_ID,
  }
}

export class UsageStoreNotConfigured extends Error {
  constructor() {
    super('usage store not configured: set KV_REST_API_URL/KV_REST_API_TOKEN (Upstash)')
  }
}

/**
 * @param overrides test hooks for the app's side effects (as in `createApp`)
 * @param redisFetch test hook for the Upstash REST calls (default: global fetch)
 */
export function createVercelApp(env: VercelEnv, overrides: Partial<Deps> = {}, redisFetch?: typeof fetch) {
  const redis = redisConfigFromEnv(env)
  const counter = redis === null ? null : new RedisUsageCounter(redis, redisFetch)
  const inner = createApp({
    usageCounter: () => {
      if (counter === null) throw new UsageStoreNotConfigured()
      return counter
    },
    ...overrides,
  })
  const bindings = bindingsFromEnv(env)
  const app = new Hono()
  app.all('*', (c) => inner.fetch(c.req.raw, bindings))
  return app
}
