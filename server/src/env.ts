import { type KvStore, KvUsageCounter, type UsageCounter } from './usage.js'

/**
 * Configuration. Cloudflare: wrangler.jsonc vars + KV, and secrets set with `wrangler secret put`.
 * Vercel: project environment variables, passed in by src/vercel.ts.
 */
export interface Bindings {
  /** Cloudflare KV namespace for the usage counter (Worker target only). */
  USAGE?: KvStore
  /** "mock" selects the deterministic stand-in; anything else calls the real API (when a key is set). */
  JEV_MODE?: string
  REVENUECAT_MODE?: string
  JEV_API_KEY?: string
  /** RevenueCat REST API v2 secret key (`sk_…`). */
  REVENUECAT_SECRET_KEY?: string
  /** RevenueCat project id; API v2 paths are per project. */
  REVENUECAT_PROJECT_ID?: string
  APP_TOKEN?: string
}

/** Injectable side effects, so tests can control the network, the clock and the counter store. */
export interface Deps {
  fetch: typeof fetch
  now: () => Date
  /** Per-call timeout for upstream APIs (Jev: 2 s per docs/CONTRACTS.md §5). */
  upstreamTimeoutMs: number
  /** Monthly fill counter for a request's bindings. */
  usageCounter: (env: Bindings) => UsageCounter
}

export const defaultDeps: Deps = {
  // Wrapped so `fetch` is never invoked with a foreign `this`.
  fetch: (input, init) => fetch(input, init),
  now: () => new Date(),
  upstreamTimeoutMs: 3000, // Jev p95 observed 0.2-0.4 s with occasional multi-second spikes
  // Cloudflare: the `USAGE` KV binding. The Vercel entry (src/vercel.ts) overrides this with Redis.
  usageCounter: (env) => {
    if (env.USAGE === undefined) throw new Error('USAGE KV binding missing')
    return new KvUsageCounter(env.USAGE)
  },
}

export class TimeoutError extends Error {
  constructor() {
    super('upstream timeout')
  }
}

/**
 * Runs `work` (request + body parsing) under a hard deadline. Rejects with TimeoutError even if
 * the underlying fetch ignores the abort signal.
 */
export async function withTimeout<T>(
  deps: Deps,
  work: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController()
  let timer: ReturnType<typeof setTimeout> | undefined
  const deadline = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort()
      reject(new TimeoutError())
    }, deps.upstreamTimeoutMs)
  })
  try {
    return await Promise.race([work(controller.signal), deadline])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}
