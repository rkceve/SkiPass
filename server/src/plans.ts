// The single table of plan id -> RevenueCat entitlement id -> monthly fill limit (docs/CONTRACTS.md §5).
// Note: the limits (free 10 / standard 100 / pro 1000 fills per month) are provisional values;
// changing them here changes both enforcement and `GET /v1/usage`.

export type PlanId = 'free' | 'standard' | 'pro'

export interface Plan {
  id: PlanId
  /**
   * RevenueCat entitlement identifier that grants this plan; null for the free plan. This is the
   * entitlement's `lookup_key` in API v2 (the identifier the SDKs use), not its `entl…` object id.
   */
  entitlementId: string | null
  monthlyFillLimit: number
}

/**
 * Paid plans in priority order: the first one whose entitlement is active wins,
 * so list the highest tier first.
 */
export const PAID_PLANS: readonly Plan[] = [
  { id: 'pro', entitlementId: 'pro', monthlyFillLimit: 1000 },
  { id: 'standard', entitlementId: 'standard', monthlyFillLimit: 100 },
]

export const FREE_PLAN: Plan = { id: 'free', entitlementId: null, monthlyFillLimit: 10 }

/** Plan by id (for the cached last known plan); undefined for an id not in this table. */
export function planById(id: string): Plan | undefined {
  return [...PAID_PLANS, FREE_PLAN].find((p) => p.id === id)
}
