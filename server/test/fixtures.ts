// Upstream payloads copied from the official docs' example payloads (Jev fetched 2026-09-23,
// RevenueCat API v2 fetched 2026-09-27). Substitutions are noted per fixture.

/**
 * Jev response. Source: https://docs.typesafe.ai/api.md, "Noul answer" example response:
 * {"model":"jev-1.13.0","answers":{"is_urgent":{"type":"noul","noul":0.95}},
 *  "usage":{"input_tokens":307,"output_tokens":20}}
 * Substituted: question id `is_urgent` -> `is_code_for_service`, and `noul`.
 */
export function jevResponse(noul: number) {
  return {
    model: 'jev-1.13.0',
    answers: {
      is_code_for_service: {
        type: 'noul',
        noul,
      },
    },
    usage: { input_tokens: 307, output_tokens: 20 },
  }
}

/**
 * RevenueCat API v2 "Get a list of entitlements" item, from the docs' response sample
 * (https://www.revenuecat.com/docs/api-v2/entitlement):
 * {"object":"entitlement","id":"entla1b2c3d4e5","lookup_key":"premium","display_name":"Premium"}
 * Substituted: `id`, `lookup_key`, `display_name`.
 */
export function rcEntitlement(id: string, lookupKey: string) {
  return { object: 'entitlement', id, lookup_key: lookupKey, display_name: lookupKey }
}

/** Entitlement object ids used by the tests, one per lookup key in plans.ts. */
export const RC_ENTITLEMENT_IDS: Record<string, string> = {
  pro: 'entla1b2c3d4e5',
  standard: 'entlb2c3d4e5f6',
}

/** v2 list envelope (`object`, `items`, `next_page`, `url`), as in the docs' list samples. */
export function rcList(url: string, items: unknown[], nextPage: string | null = null) {
  return { object: 'list', items, next_page: nextPage, url }
}

/** A project's entitlement list: `premium` (the docs' sample, not in plans.ts) plus pro/standard. */
export function rcEntitlementList(project: string) {
  return rcList(`/v2/projects/${project}/entitlements`, [
    rcEntitlement('entlc3d4e5f6a7', 'premium'),
    ...Object.entries(RC_ENTITLEMENT_IDS).map(([key, id]) => rcEntitlement(id, key)),
  ])
}

/**
 * Active entitlement item, from the "Get a customer" docs sample's `active_entitlements`
 * (https://www.revenuecat.com/docs/api-v2/customer):
 * {"object":"customer.active_entitlement","entitlement_id":"entla1b2c3d4e5","expires_at":1658399423658}
 * Substituted: `entitlement_id`, `expires_at`.
 */
export function rcActiveEntitlement(entitlementId: string, expiresAt: number | null) {
  return { object: 'customer.active_entitlement', entitlement_id: entitlementId, expires_at: expiresAt }
}

/** The docs sample's `expires_at` (2022-07-21T10:30:23.658Z), used as a realistic non-null value. */
export const RC_SAMPLE_EXPIRES_AT = 1658399423658

/** v2 error for an unknown customer, verbatim from the live API (2026-09-27, HTTP 404). */
export const rcCustomerMissing = {
  doc_url: 'https://errors.rev.cat/resource-missing',
  message: 'Could not find customer ID associated with this project',
  object: 'error',
  retryable: false,
  type: 'resource_missing',
}

/** Message text in the exact layout of `FetchedMessage.judgeText` (SkiPassModels). */
export function judgeText(p: { from: string; to: string; subject: string; date: string; body: string }) {
  return `From: ${p.from}\nTo: ${p.to}\nSubject: ${p.subject}\nDate: ${p.date}\n\n${p.body}`
}
