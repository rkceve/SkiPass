// Shared types for eval/generate.ts and eval/run.ts.

export type Kind = 'otp' | 'promo' | 'order' | 'notice'

export interface ScenarioEmail {
  id: string
  from: string
  to: string
  subject: string
  /** ISO 8601 without fractional seconds, like Foundation's ISO8601DateFormatter. */
  date: string
  body: string
  /** Exactly `FetchedMessage.judgeText`: headers, blank line, body. This is what strategies see. */
  text: string
  /** The code-like string the extractor would have pulled out of this email. */
  code: string
  kind: Kind
  /** Registrable domain of the site this email really belongs to (ground-truth bookkeeping only). */
  owner: string
}

export interface Scenario {
  id: string
  category: Category
  description: string
  /** Service identifier as the extension sends it: the requesting site's host. */
  service: string
  emails: ScenarioEmail[]
  /** Id of the one correct email, or null when no email is the code for `service`. */
  correct: string | null
}

export const CATEGORIES = [
  'older_target',
  'brand_via_provider',
  'domain_in_link_only',
  'same_site_two_codes',
  'promo_codes',
  'order_invoice_numbers',
  'japanese',
  'subdomain_site',
  'no_correct',
] as const
export type Category = (typeof CATEGORIES)[number]

export const CATEGORY_NOTES: Record<Category, string> = {
  older_target: "Target site's code email is older than another site's code email",
  brand_via_provider:
    'Target email sent through a mail-provider domain; brand name only in the text, site domain nowhere',
  domain_in_link_only: 'Target email names a different company/brand; the site domain appears only in a link',
  same_site_two_codes: 'Two code emails from the target site (resend); the newest one is correct',
  promo_codes: "A newer promotional email (often the target site's own) carries a discount/referral code",
  order_invoice_numbers: 'A newer order confirmation / invoice / booking / receipt carries a number',
  japanese: 'Japanese-language emails (code, coupon, order) for Japanese-named fictional sites',
  subdomain_site:
    'Requesting host is a subdomain (login.<x>.co.uk, accounts.<x>.example) or a *.vercel.app private-suffix site',
  no_correct: 'No email is the code for the requesting site (correct answer: fill nothing)',
}

