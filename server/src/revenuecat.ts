// RevenueCat REST API v2 plan lookup.
//
// API v1 (`/v1/subscribers`) is not usable: it rejects v2 secret keys (verified 2026-09-27:
// HTTP 403 {"code":7723,"message":"You're trying to use a secret API key incompatible with
// RevenueCat API V1."}), and https://www.revenuecat.com/docs/api-v2 states v1 and v2 keys are separate.
//
// API v2, base https://api.revenuecat.com/v2, `Authorization: Bearer <v2 secret key>`
// (https://www.revenuecat.com/docs/api-v2, "Authentication"):
//   GET /projects/{project_id}/entitlements            — permission project_configuration:entitlements:read
//       -> {object:"list", items:[{object:"entitlement", id:"entl…", lookup_key, display_name, …}], next_page}
//       (https://www.revenuecat.com/docs/api-v2/entitlement, "Get a list of entitlements")
//   GET /projects/{project_id}/customers/{customer_id}/active_entitlements
//                                                      — permission customer_information:customers:read
//       -> {object:"list", items:[{object:"customer.active_entitlement", entitlement_id:"entl…",
//           expires_at: <ms> | null}], next_page}; 404 resource_missing for an unknown customer.
//       (https://www.revenuecat.com/docs/api-v2/customer — the `active_entitlements` list that
//       "Get a customer" embeds, with its `url`; shape confirmed against the live project 2026-09-27.)
// Active entitlements carry the object id (`entl…`), while plans.ts names entitlements by lookup
// key, so the project's entitlement list (id -> lookup_key) is fetched too and cached per isolate.

import { type Deps, withTimeout } from './env.js'
import { FREE_PLAN, PAID_PLANS, type Plan } from './plans.js'

export const REVENUECAT_BASE = 'https://api.revenuecat.com/v2'
/** How long the entitlement id -> lookup_key table is reused. */
export const ENTITLEMENT_CACHE_MS = 10 * 60 * 1000

interface ListResponse<T> {
  items?: T[]
  next_page?: string | null
}

interface EntitlementItem {
  id?: string
  lookup_key?: string
}

interface ActiveEntitlementItem {
  entitlement_id?: string
  expires_at?: number | null
}

/** Active = `expires_at` null (no expiry) or in the future (milliseconds since epoch). */
export function isEntitlementActive(expiresAt: number | null | undefined, now: Date): boolean {
  if (expiresAt === null) return true
  return typeof expiresAt === 'number' && Number.isFinite(expiresAt) && expiresAt > now.getTime()
}

/** First plan in PAID_PLANS order whose entitlement lookup key is active; otherwise the free plan. */
export function planFromLookupKeys(activeLookupKeys: ReadonlySet<string>): Plan {
  for (const plan of PAID_PLANS) {
    if (plan.entitlementId !== null && activeLookupKeys.has(plan.entitlementId)) return plan
  }
  return FREE_PLAN
}

export interface RevenueCatConfig {
  mode: 'live' | 'mock'
  secretKey: string
  projectId: string
}

const entitlementCache = new Map<string, { at: number; lookupKeys: Map<string, string> }>()

/** Test hook: forget cached entitlement tables. */
export function clearEntitlementCache(): void {
  entitlementCache.clear()
}

class NotFound extends Error {}

async function getList<T>(deps: Deps, rc: RevenueCatConfig, path: string, signal: AbortSignal): Promise<T[]> {
  const items: T[] = []
  let next: string | null = `/projects/${encodeURIComponent(rc.projectId)}${path}`
  // `next_page` is a path under /v2 (per the docs' list responses); follow a few pages at most.
  for (let page = 0; next !== null && page < 10; page++) {
    const res = await deps.fetch(`${REVENUECAT_BASE}${next.replace(/^\/v2/, '')}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${rc.secretKey}`, Accept: 'application/json' },
      signal,
    })
    if (res.status === 404) throw new NotFound()
    if (!res.ok) throw new Error(`revenuecat http ${res.status}`)
    const body = (await res.json()) as ListResponse<T>
    items.push(...(body.items ?? []))
    next = typeof body.next_page === 'string' && body.next_page !== '' ? body.next_page : null
  }
  return items
}

async function entitlementLookupKeys(
  deps: Deps,
  rc: RevenueCatConfig,
  signal: AbortSignal,
): Promise<Map<string, string>> {
  const cached = entitlementCache.get(rc.projectId)
  const nowMs = deps.now().getTime()
  if (cached !== undefined && nowMs - cached.at < ENTITLEMENT_CACHE_MS && nowMs >= cached.at) {
    return cached.lookupKeys
  }
  const items = await getList<EntitlementItem>(deps, rc, '/entitlements?limit=100', signal)
  const lookupKeys = new Map<string, string>()
  for (const e of items) {
    if (typeof e.id === 'string' && typeof e.lookup_key === 'string') lookupKeys.set(e.id, e.lookup_key)
  }
  entitlementCache.set(rc.projectId, { at: nowMs, lookupKeys })
  return lookupKeys
}

export async function lookupPlan(
  deps: Deps,
  rc: RevenueCatConfig,
  appUserID: string,
): Promise<Plan> {
  if (rc.mode === 'mock') return FREE_PLAN
  try {
    return await withTimeout(deps, async (signal) => {
      const [lookupKeys, active] = await Promise.all([
        entitlementLookupKeys(deps, rc, signal),
        getList<ActiveEntitlementItem>(
          deps,
          rc,
          `/customers/${encodeURIComponent(appUserID)}/active_entitlements`,
          signal,
        ).catch((e: unknown) => {
          // Unknown customer (never opened the app with RevenueCat) -> no entitlements.
          if (e instanceof NotFound) return []
          throw e
        }),
      ])
      const now = deps.now()
      const activeKeys = new Set<string>()
      for (const a of active) {
        if (typeof a.entitlement_id !== 'string' || !isEntitlementActive(a.expires_at, now)) continue
        const key = lookupKeys.get(a.entitlement_id)
        if (key !== undefined) activeKeys.add(key)
      }
      return planFromLookupKeys(activeKeys)
    })
  } catch {
    // OPEN(billing): behaviour when RevenueCat is unreachable is not decided; degrade to the free plan.
    return FREE_PLAN
  }
}
