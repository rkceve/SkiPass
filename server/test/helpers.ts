import { env } from 'cloudflare:workers'
import { createApp } from '../src/api'
import type { Bindings, Deps } from '../src/env'
import { clearEntitlementCache } from '../src/revenuecat'

export const TOKEN = 'test-app-token'
/** Project id from the RevenueCat API v2 docs' samples. */
export const RC_PROJECT = 'proj1ab2c3d4'

let userCounter = 0
/** KV storage is isolated per test file, not per test, so every test uses its own user id. */
export function freshUser(): string {
  userCounter += 1
  return `$RCAnonymousID:test-${Date.now()}-${userCounter}`
}

export interface RecordedCall {
  url: string
  init: RequestInit
}

export type Route = (url: string, init: RequestInit) => Response | Promise<Response>

/** A fetch stand-in that records calls and answers through `route`. */
export function fakeFetch(route: Route) {
  const calls: RecordedCall[] = []
  const fn = (async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
    calls.push({ url, init })
    return await route(url, init)
  }) as typeof fetch
  return { fn, calls }
}

export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

/** A fetch that never settles (for timeout tests). */
export const hang: Route = () => new Promise<Response>(() => {})

let ipCounter = 0
/** A distinct client IP per test client, so the per-IP judge limit of one test never leaks into another. */
export function freshIp(): string {
  ipCounter += 1
  return `203.0.113.${ipCounter % 250}:${Date.now()}`
}

export function makeClient(opts: {
  bindings?: Partial<Bindings>
  deps?: Partial<Deps>
  user?: string
  token?: string | null
  ip?: string
}) {
  // Every client starts with an empty RevenueCat entitlement table cache.
  clearEntitlementCache()
  const app = createApp(opts.deps)
  const bindings: Bindings = {
    USAGE: env.USAGE,
    APP_TOKEN: TOKEN,
    JEV_MODE: 'mock',
    REVENUECAT_MODE: 'mock',
    REVENUECAT_PROJECT_ID: RC_PROJECT,
    ...opts.bindings,
  }
  const user = opts.user ?? freshUser()
  const ip = opts.ip ?? freshIp()
  const headers = (): Record<string, string> => {
    const h: Record<string, string> = {
      'Content-Type': 'application/json',
      'X-SkiPass-User': user,
      'CF-Connecting-IP': ip,
    }
    if (opts.token !== null) h['X-SkiPass-App-Token'] = opts.token ?? TOKEN
    return h
  }
  return {
    user,
    bindings,
    judge: (body: unknown) =>
      app.request(
        '/v1/judge',
        { method: 'POST', headers: headers(), body: typeof body === 'string' ? body : JSON.stringify(body) },
        bindings,
      ),
    fill: (body: unknown) =>
      app.request(
        '/v1/fills',
        { method: 'POST', headers: headers(), body: typeof body === 'string' ? body : JSON.stringify(body) },
        bindings,
      ),
    usage: () => app.request('/v1/usage', { method: 'GET', headers: headers() }, bindings),
    raw: (path: string, init: RequestInit) => app.request(path, init, bindings),
  }
}
