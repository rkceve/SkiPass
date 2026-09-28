// Jev (TypeSafe AI) System One call and candidate selection, per docs/API.md.
//
// HTTP API (not the Node SDK, whose Workers compatibility is unverified):
//   POST https://api.typesafe.ai/v1/systemone, `Authorization: Bearer <API_KEY>`,
//   body {state, model, questions: {<id>: {type: "noul", instructions, criteria?: {true, false}}}}
//   response {model, answers: {<id>: {type: "noul", noul: number}}, usage}
//   Source: https://docs.typesafe.ai/api.md ("Evaluation endpoint", "Request body", "Noul",
//   "Noul answer") and https://docs.typesafe.ai/primitives/noul.md ("Request structure",
//   "Response structure"), both fetched 2026-09-23.

import { getDomain, getDomainWithoutSuffix, getHostname } from 'tldts'
import { type Deps, withTimeout } from './env.js'

export const JEV_URL = 'https://api.typesafe.ai/v1/systemone'
export const JEV_MODEL = 'jev-latest'
export const QUESTION_ID = 'is_code_for_service'
export const NOUL_THRESHOLD = 0.5

export interface JudgeMessage {
  id: string
  text: string
}

export interface JudgeResult {
  chosenId: string | null
  scores: Record<string, number>
  /** `mock` only when JEV_MODE=mock (docs/API.md, Server configuration). */
  source: 'jev' | 'fallback' | 'mock'
}

interface NoulQuestion {
  type: 'noul'
  instructions: string
  criteria?: { true: string; false: string }
}

/** The Noul question for `service`, with instructions/criteria exactly as in docs/API.md. */
export function buildQuestion(service: string | null): NoulQuestion {
  if (service === null) {
    // docs/API.md gives no criteria for the service-null case; `criteria` is optional per
    // https://docs.typesafe.ai/primitives/noul.md ("criteria: Optional."), so it is omitted.
    return {
      type: 'noul',
      instructions: 'Is this email delivering a one-time verification or sign-in code?',
    }
  }
  return {
    type: 'noul',
    // Wording chosen by a live comparison against jev-1.13.0 (2026-09-27): the correct code email
    // scored 0.87 vs 0.65 with the original wording, while other-site code emails and promotions
    // stayed at 0.01-0.02.
    instructions:
      `A user is signing in on the website ${service} and needs the one-time code that this website just emailed them. ` +
      `Is this email that code email from ${service} (the sender may use a different brand name or email provider, ` +
      `but the email mentions or links to ${service})?`,
    criteria: {
      true: `A one-time verification code email sent by or for ${service}`,
      false: 'A code email from a different website, a promotional email, or an email without a one-time code',
    },
  }
}

export function buildRequestBody(service: string | null, text: string) {
  return {
    state: text,
    model: JEV_MODEL,
    questions: { [QUESTION_ID]: buildQuestion(service) },
  }
}

/**
 * Public Suffix List including its PRIVATE section, so hosting suffixes such as `vercel.app` and
 * `github.io` count as suffixes: `skipass-demo.vercel.app` -> `skipass-demo.vercel.app`, not
 * `vercel.app`. tldts option `allowPrivateDomains` (default false):
 * https://github.com/remusao/tldts#readme ("allowPrivateDomains").
 */
const TLD_OPTIONS = { allowPrivateDomains: true } as const

/** Registrable domain (eTLD+1, private suffixes included) of a service identifier (bare host or URL), lowercased. */
export function registrableDomain(service: string): string | null {
  const s = service.trim().toLowerCase()
  if (s === '') return null
  return getDomain(s, TLD_OPTIONS) ?? getHostname(s) ?? s
}

/** Brand word = registrable domain without its public suffix ("acme.co.uk" -> "acme", "skipass-demo.vercel.app" -> "skipass-demo"). */
export function brandWord(service: string): string | null {
  const s = service.trim().toLowerCase()
  if (s === '') return null
  return getDomainWithoutSuffix(s, TLD_OPTIONS)
}

/**
 * Message date from the `Date:` header line of the text built by `FetchedMessage.judgeText`
 * (headers, blank line, body). Unparseable/missing -> -Infinity (treated as oldest).
 */
export function messageTime(text: string): number {
  for (const line of text.split('\n')) {
    if (line.trim() === '') break // end of the header block
    if (line.startsWith('Date: ')) {
      const t = Date.parse(line.slice('Date: '.length).trim())
      return Number.isNaN(t) ? -Infinity : t
    }
  }
  return -Infinity
}

/** Index of the newest message among `indices` (first one wins on equal dates). */
function newestOf(messages: JudgeMessage[], indices: number[]): number | null {
  let best: number | null = null
  for (const i of indices) {
    if (best === null || messageTime(messages[i].text) > messageTime(messages[best].text)) best = i
  }
  return best
}

/**
 * Scores this close to the best one are treated as a tie. Jev scores a resent code and the
 * original about equally (0.96 vs 0.97 in eval/RESULTS.md); among near-equal matches the newest
 * email is the one the user just asked for.
 */
export const SCORE_TIE_MARGIN = 0.05

/** Best noul >= 0.5; scores within SCORE_TIE_MARGIN of the best -> newest Date; none -> null. */
export function selectByScores(
  messages: JudgeMessage[],
  scores: Record<string, number>,
): string | null {
  let bestScore = -Infinity
  messages.forEach((m) => {
    const s = scores[m.id]
    if (s !== undefined && s >= NOUL_THRESHOLD && s > bestScore) bestScore = s
  })
  if (bestScore === -Infinity) return null
  const near = messages
    .map((m, i) => ({ s: scores[m.id], i }))
    .filter(({ s }) => s !== undefined && s >= NOUL_THRESHOLD && s >= bestScore - SCORE_TIE_MARGIN)
    .map(({ i }) => i)
  const i = newestOf(messages, near)
  return i === null ? null : messages[i].id
}

/** Fallback: newest message containing the service's registrable domain, else newest message. */
export function fallbackSelect(service: string | null, messages: JudgeMessage[]): string | null {
  const all = messages.map((_, i) => i)
  const domain = service === null ? null : registrableDomain(service)
  if (domain !== null) {
    const matching = all.filter((i) => messages[i].text.toLowerCase().includes(domain))
    const i = newestOf(messages, matching)
    if (i !== null) return messages[i].id
  }
  const i = newestOf(messages, all)
  return i === null ? null : messages[i].id
}

/** Deterministic stand-in for Jev (JEV_MODE=mock only): domain or brand word in text -> 0.9, else 0.1. */
export function mockNoul(service: string | null, text: string): number {
  if (service === null) return 0.1
  const lower = text.toLowerCase()
  const domain = registrableDomain(service)
  const brand = brandWord(service)
  if ((domain !== null && lower.includes(domain)) || (brand !== null && lower.includes(brand))) {
    return 0.9
  }
  return 0.1
}

/** One Jev call for one message. Throws on HTTP error, timeout, or an unexpected response shape. */
export async function callJev(
  deps: Deps,
  apiKey: string,
  service: string | null,
  text: string,
): Promise<number> {
  return withTimeout(deps, async (signal) => {
    const res = await deps.fetch(JEV_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(buildRequestBody(service, text)),
      signal,
    })
    if (!res.ok) throw new Error(`jev http ${res.status}`)
    const json = (await res.json()) as {
      answers?: Record<string, { type?: string; noul?: unknown }>
    }
    const noul = json.answers?.[QUESTION_ID]?.noul
    if (typeof noul !== 'number' || !Number.isFinite(noul) || noul < 0 || noul > 1) {
      throw new Error('jev unexpected response')
    }
    return noul
  })
}

export interface JevConfig {
  /** `unconfigured` = live mode without an API key (a config error; every judge uses the fallback rule). */
  mode: 'live' | 'mock' | 'unconfigured'
  apiKey: string
}

const fallbackResult = (service: string | null, messages: JudgeMessage[]): JudgeResult => ({
  chosenId: fallbackSelect(service, messages),
  scores: {},
  source: 'fallback',
})

/**
 * Judges all messages in parallel (one Noul question per message). Any Jev failure or timeout
 * switches the whole request to the fallback rule, with `source: "fallback"`.
 */
export async function judgeMessages(
  deps: Deps,
  jev: JevConfig,
  service: string | null,
  messages: JudgeMessage[],
): Promise<JudgeResult> {
  if (jev.mode === 'mock') {
    // Without a service there is nothing to score against: the mock applies the fallback rule.
    if (service === null) return { chosenId: fallbackSelect(null, messages), scores: {}, source: 'mock' }
    const scores: Record<string, number> = {}
    for (const m of messages) scores[m.id] = mockNoul(service, m.text)
    return { chosenId: selectByScores(messages, scores), scores, source: 'mock' }
  }
  if (jev.mode === 'unconfigured') return fallbackResult(service, messages)
  try {
    const values = await Promise.all(messages.map((m) => callJev(deps, jev.apiKey, service, m.text)))
    const scores: Record<string, number> = {}
    messages.forEach((m, i) => (scores[m.id] = values[i]))
    return { chosenId: selectByScores(messages, scores), scores, source: 'jev' }
  } catch {
    // Deliberately no logging: error objects could carry request content (docs/ARCHITECTURE.md §4: no content logging).
    return fallbackResult(service, messages)
  }
}
