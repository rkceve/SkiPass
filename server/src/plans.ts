// The single table of plan id -> RevenueCat entitlement id -> monthly fill limit (docs/CONTRACTS.md §5).
// OPEN(plans): values not decided — plan names, entitlement ids and limits below are placeholders.

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
  { id: 'pro', entitlementId: 'pro', monthlyFillLimit: 1000 }, // OPEN(plans): values not decided
  { id: 'standard', entitlementId: 'standard', monthlyFillLimit: 100 }, // OPEN(plans): values not decided
]

export const FREE_PLAN: Plan = { id: 'free', entitlementId: null, monthlyFillLimit: 10 } // OPEN(plans): values not decided
