// Compares three candidate-selection strategies on eval/scenarios.json:
//   baseline  - newest message that carries a code
//   heuristic - the server's fallback rule `fallbackSelect` (server/src/jev.ts)
//   jev       - the server's per-message Noul question (`buildRequestBody`) sent to the real Jev API,
//               then the server's `selectByScores`
//
// Usage (from the repo root or eval/):
//   JEV_API_KEY=... npx tsx eval/run.ts    real run; writes eval/results.json and eval/RESULTS.md
//   npx tsx eval/run.ts --dry              no Jev calls; prints baseline/heuristic only, writes nothing
//
// The API key is only read from the environment (or the file named by JEV_API_KEY_FILE) and only placed in the Authorization header.

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  JEV_URL,
  QUESTION_ID,
  buildRequestBody,
  fallbackSelect,
  messageTime,
  selectByScores,
  type JudgeMessage,
} from '../server/src/jev.ts'
import { CATEGORIES, CATEGORY_NOTES, type Category, type Scenario } from './types.ts'

const HERE = dirname(fileURLToPath(import.meta.url))
const DRY = process.argv.includes('--dry')
/** Jev input price: $0.042 per million input tokens; output tokens are free (https://docs.typesafe.ai/models). */
const USD_PER_MTOK = 0.042
/** Production per-call timeout (server/src/env.ts defaultDeps.upstreamTimeoutMs). Not enforced here; only counted. */
const PROD_TIMEOUT_MS = 3000
const MAX_CONCURRENCY = 5
const MAX_ATTEMPTS = 6

type Strategy = 'baseline' | 'heuristic' | 'jev'
const STRATEGIES: Strategy[] = ['baseline', 'heuristic', 'jev']
const STRATEGY_LABEL: Record<Strategy, string> = {
  baseline: 'Newest code (baseline)',
  heuristic: 'Domain heuristic (`fallbackSelect`)',
  jev: 'Jev (`buildRequestBody` + `selectByScores`)',
}

type Outcome = 'correct' | 'false_fill' | 'miss' | 'error'

// ---------------------------------------------------------------------------------------------
// Strategies

/** Newest message with a code. All scenario emails carry a code (they passed the extractor). */
function baselineSelect(scenario: Scenario, messages: JudgeMessage[]): string | null {
  let best: number | null = null
  scenario.emails.forEach((e, i) => {
    if (e.code === '') return
    if (best === null || messageTime(messages[i].text) > messageTime(messages[best].text)) best = i
  })
  return best === null ? null : messages[best].id
}

interface JevCall {
  messageId: string
  noul: number | null
  latencyMs: number | null
  attempts: number
  inputTokens: number
  outputTokens: number
  model: string | null
  error: string | null
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/**
 * One Jev call with the exact production request body. Retries 429/529 (and network errors) with
 * exponential backoff + jitter, per https://docs.typesafe.ai/api.md ("retry the request with
 * exponential backoff instead of retrying immediately"). Latency = the final attempt only.
 */
async function callJev(apiKey: string, service: string, m: JudgeMessage): Promise<JevCall> {
  const body = JSON.stringify(buildRequestBody(service, m.text))
  let lastError = 'unknown'
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const t0 = performance.now()
    let res: Response
    try {
      res = await fetch(JEV_URL, {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body,
        signal: AbortSignal.timeout(30_000),
      })
    } catch (e) {
      lastError = `network: ${(e as Error).name}`
      await sleep(backoff(attempt))
      continue
    }
    if (res.status === 429 || res.status === 529) {
      await res.body?.cancel()
      lastError = `http ${res.status}`
      await sleep(backoff(attempt))
      continue
    }
    if (!res.ok) {
      await res.body?.cancel()
      return failed(m.id, attempt, `http ${res.status}`)
    }
    const json = (await res.json()) as {
      model?: string
      answers?: Record<string, { noul?: unknown }>
      usage?: { input_tokens?: number; output_tokens?: number }
    }
    const latencyMs = performance.now() - t0
    const noul = json.answers?.[QUESTION_ID]?.noul
    if (typeof noul !== 'number' || !Number.isFinite(noul) || noul < 0 || noul > 1) {
      return failed(m.id, attempt, 'unexpected response')
    }
    return {
      messageId: m.id,
      noul,
      latencyMs,
      attempts: attempt,
      inputTokens: json.usage?.input_tokens ?? 0,
      outputTokens: json.usage?.output_tokens ?? 0,
      model: json.model ?? null,
      error: null,
    }
  }
  return failed(m.id, MAX_ATTEMPTS, `gave up: ${lastError}`)
}

function backoff(attempt: number) {
  return 500 * 2 ** (attempt - 1) + Math.floor(Math.random() * 250)
}

function failed(messageId: string, attempts: number, error: string): JevCall {
  return { messageId, noul: null, latencyMs: null, attempts, inputTokens: 0, outputTokens: 0, model: null, error }
}

/** Runs `tasks` with at most `limit` in flight. */
async function pool<T>(limit: number, tasks: (() => Promise<T>)[]): Promise<T[]> {
  const out: T[] = new Array(tasks.length)
  let next = 0
  const workers = Array.from({ length: Math.min(limit, tasks.length) }, async () => {
    while (next < tasks.length) {
      const i = next++
      out[i] = await tasks[i]()
    }
  })
  await Promise.all(workers)
  return out
}

// ---------------------------------------------------------------------------------------------
// Scoring

function outcome(pick: string | null, correct: string | null): Outcome {
  if (pick === correct) return 'correct'
  if (pick === null) return 'miss'
  return 'false_fill'
}

interface Tally {
  n: number
  correct: number
  false_fill: number
  miss: number
  error: number
}
const emptyTally = (): Tally => ({ n: 0, correct: 0, false_fill: 0, miss: 0, error: 0 })

/** Nearest-rank percentile. */
function pct(values: number[], p: number): number | null {
  if (values.length === 0) return null
  const s = [...values].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1))]
}

const ms = (v: number | null) => (v === null ? 'n/a' : `${Math.round(v)} ms`)
const pc = (a: number, n: number) => (n === 0 ? 'n/a' : `${((100 * a) / n).toFixed(1)}%`)

// ---------------------------------------------------------------------------------------------

interface ScenarioResult {
  id: string
  category: Category
  service: string
  correct: string | null
  picks: Record<Strategy, string | null>
  outcomes: Record<Strategy, Outcome>
  jev?: { wallMs: number; calls: JevCall[] }
}

async function main() {
  const data = JSON.parse(readFileSync(join(HERE, 'scenarios.json'), 'utf8')) as { scenarios: Scenario[] }
  const scenarios = data.scenarios
  // JEV_API_KEY, or JEV_API_KEY_FILE = path to a file holding only the key.
  const keyFile = process.env.JEV_API_KEY_FILE
  const apiKey = (process.env.JEV_API_KEY ?? (keyFile ? readFileSync(keyFile, 'utf8') : '')).trim()
  if (!DRY && apiKey === '') {
    console.error('JEV_API_KEY (or JEV_API_KEY_FILE) is not set (use --dry to skip Jev).')
    process.exit(2)
  }

  const results: ScenarioResult[] = []
  const startedAt = new Date()
  for (const s of scenarios) {
    const messages: JudgeMessage[] = s.emails.map((e) => ({ id: e.id, text: e.text }))
    const picks: Record<Strategy, string | null> = {
      baseline: baselineSelect(s, messages),
      heuristic: fallbackSelect(s.service, messages),
      jev: null,
    }
    const outcomes: Record<Strategy, Outcome> = {
      baseline: outcome(picks.baseline, s.correct),
      heuristic: outcome(picks.heuristic, s.correct),
      jev: 'error',
    }
    const r: ScenarioResult = { id: s.id, category: s.category, service: s.service, correct: s.correct, picks, outcomes }
    if (!DRY) {
      // Like production (Promise.all per request): all messages of one scenario in flight at once
      // (2-5 <= MAX_CONCURRENCY), scenarios one after another.
      const t0 = performance.now()
      const calls = await pool(
        MAX_CONCURRENCY,
        messages.map((m) => () => callJev(apiKey, s.service, m)),
      )
      const wallMs = performance.now() - t0
      r.jev = { wallMs, calls }
      if (calls.every((c) => c.noul !== null)) {
        const scores: Record<string, number> = {}
        for (const c of calls) scores[c.messageId] = c.noul as number
        picks.jev = selectByScores(messages, scores)
        outcomes.jev = outcome(picks.jev, s.correct)
      }
      const nouls = calls.map((c) => (c.noul === null ? c.error : c.noul.toFixed(3))).join(' ')
      console.log(`${s.id.padEnd(26)} jev=${outcomes.jev.padEnd(10)} ${Math.round(wallMs)}ms  [${nouls}]`)
    }
    results.push(r)
  }

  const active = DRY ? (['baseline', 'heuristic'] as Strategy[]) : STRATEGIES
  const total: Record<Strategy, Tally> = { baseline: emptyTally(), heuristic: emptyTally(), jev: emptyTally() }
  const perCat: Record<string, Record<Strategy, Tally>> = {}
  const bySubset: Record<'has_correct' | 'none_correct', Record<Strategy, Tally>> = {
    has_correct: { baseline: emptyTally(), heuristic: emptyTally(), jev: emptyTally() },
    none_correct: { baseline: emptyTally(), heuristic: emptyTally(), jev: emptyTally() },
  }
  for (const r of results) {
    perCat[r.category] ??= { baseline: emptyTally(), heuristic: emptyTally(), jev: emptyTally() }
    for (const st of active) {
      for (const t of [total[st], perCat[r.category][st], bySubset[r.correct === null ? 'none_correct' : 'has_correct'][st]]) {
        t.n++
        t[r.outcomes[st]]++
      }
    }
  }

  if (DRY) {
    console.log(`DRY run (no Jev calls), ${results.length} scenarios`)
    for (const st of active) {
      const t = total[st]
      console.log(`${st.padEnd(10)} accuracy ${t.correct}/${t.n} (${pc(t.correct, t.n)})  false fills ${t.false_fill}  misses ${t.miss}`)
    }
    for (const c of CATEGORIES) {
      console.log(`  ${c.padEnd(22)} ` + active.map((st) => `${st}=${perCat[c][st].correct}/${perCat[c][st].n}`).join(' '))
    }
    return
  }

  // Jev stats
  const calls = results.flatMap((r) => r.jev?.calls ?? [])
  const okCalls = calls.filter((c) => c.latencyMs !== null)
  const reqLat = okCalls.map((c) => c.latencyMs as number)
  const scenLat = results.filter((r) => r.outcomes.jev !== 'error').map((r) => (r.jev as { wallMs: number }).wallMs)
  const inTok = calls.reduce((a, c) => a + c.inputTokens, 0)
  const outTok = calls.reduce((a, c) => a + c.outputTokens, 0)
  const costUsd = (inTok / 1e6) * USD_PER_MTOK
  const models = [...new Set(calls.map((c) => c.model).filter((m): m is string => m !== null))]
  const retried = calls.filter((c) => c.attempts > 1).length
  const overTimeout = reqLat.filter((v) => v > PROD_TIMEOUT_MS).length
  const scenOverTimeout = scenLat.filter((v) => v > PROD_TIMEOUT_MS).length
  const jevStats = {
    requests: calls.length,
    failedRequests: calls.length - okCalls.length,
    retriedRequests: retried,
    requestLatencyMs: { p50: pct(reqLat, 50), p95: pct(reqLat, 95), max: pct(reqLat, 100) },
    scenarioLatencyMs: { p50: pct(scenLat, 50), p95: pct(scenLat, 95), max: pct(scenLat, 100) },
    requestsOverProdTimeout: overTimeout,
    scenariosOverProdTimeout: scenOverTimeout,
    inputTokens: inTok,
    outputTokens: outTok,
    meanInputTokensPerRequest: calls.length === 0 ? 0 : inTok / calls.length,
    estimatedCostUsd: costUsd,
    estimatedCostUsdPerScenario: results.length === 0 ? 0 : costUsd / results.length,
    models,
  }

  const finishedAt = new Date()
  writeFileSync(
    join(HERE, 'results.json'),
    JSON.stringify(
      {
        runAt: startedAt.toISOString(),
        finishedAt: finishedAt.toISOString(),
        endpoint: JEV_URL,
        requestModel: buildRequestBody('x', 'x').model,
        scenarios: results.length,
        totals: total,
        bySubset,
        perCategory: perCat,
        jev: jevStats,
        results,
      },
      null,
      2,
    ) + '\n',
  )

  // RESULTS.md
  const L: string[] = []
  const nHas = results.filter((r) => r.correct !== null).length
  const nNone = results.length - nHas
  L.push('# Candidate-selection evaluation: newest code vs domain heuristic vs Jev', '')
  L.push(`Run: ${startedAt.toISOString()} (generated by \`eval/run.ts\`; do not edit by hand)  `)
  L.push(`Jev endpoint: \`${JEV_URL}\`, request model \`${buildRequestBody('x', 'x').model}\`, model id in responses: ${models.map((m) => `\`${m}\``).join(', ') || 'n/a'}  `)
  L.push(`Scenarios: ${results.length} (${nHas} with exactly one correct email, ${nNone} with none) — synthetic, see Method.`, '')
  L.push('## Headline', '')
  L.push('| Strategy | Accuracy | False fills | Misses | Jev errors |')
  L.push('|---|---|---|---|---|')
  for (const st of STRATEGIES) {
    const t = total[st]
    L.push(`| ${STRATEGY_LABEL[st]} | ${t.correct}/${t.n} (${pc(t.correct, t.n)}) | ${t.false_fill} | ${t.miss} | ${st === 'jev' ? t.error : '—'} |`)
  }
  L.push('')
  L.push('Accuracy = exact pick, counting "fill nothing" as correct when no email is correct. False fill = picked an email that is not the correct one (the user would get a wrong code). Miss = picked nothing although a correct email exists. Jev errors = scenarios where at least one Jev request failed after retries (not scored; production would switch that request to the fallback rule).', '')
  L.push('Split by whether a correct email exists:', '')
  L.push('| Strategy | Correct email exists: accuracy | No correct email: accuracy (= fills nothing) |')
  L.push('|---|---|---|')
  for (const st of STRATEGIES) {
    const a = bySubset.has_correct[st]
    const b = bySubset.none_correct[st]
    L.push(`| ${STRATEGY_LABEL[st]} | ${a.correct}/${a.n} (${pc(a.correct, a.n)}) | ${b.correct}/${b.n} (${pc(b.correct, b.n)}) |`)
  }
  L.push('')
  L.push('## Per category (correct / scenarios)', '')
  L.push('| Category | What it tests | n | Baseline | Heuristic | Jev |')
  L.push('|---|---|---|---|---|---|')
  for (const c of CATEGORIES) {
    const t = perCat[c]
    if (t === undefined) continue
    L.push(`| \`${c}\` | ${CATEGORY_NOTES[c]} | ${t.baseline.n} | ${t.baseline.correct} | ${t.heuristic.correct} | ${t.jev.correct}${t.jev.error ? ` (+${t.jev.error} err)` : ''} |`)
  }
  L.push('')
  const jevWrong = results.filter((r) => r.outcomes.jev !== 'correct')
  L.push('## Jev mistakes', '')
  if (jevWrong.length === 0) {
    L.push('None in this run.', '')
  } else {
    L.push('| Scenario | Description | Outcome | Correct | Picked | noul per email (oldest → newest) | Picked email is from |')
    L.push('|---|---|---|---|---|---|---|')
    for (const r of jevWrong) {
      const s = scenarios.find((x) => x.id === r.id) as Scenario
      const short = (id: string | null) => (id === null ? 'none' : id.slice(id.lastIndexOf('-') + 1))
      const nouls = (r.jev?.calls ?? []).map((c) => `${short(c.messageId)}=${c.noul === null ? c.error : c.noul.toFixed(2)}`).join(', ')
      const picked = s.emails.find((e) => e.id === r.picks.jev)
      const site = s.emails.find((e) => e.id === s.correct)?.owner
      const from = picked === undefined ? '—' : picked.owner === site ? `same site (${picked.kind}, older)` : `other: ${picked.owner} (${picked.kind})`
      L.push(`| \`${r.id}\` | ${s.description} | ${r.outcomes.jev} | ${short(r.correct)} | ${short(r.picks.jev)} | ${nouls} | ${from} |`)
    }
    L.push('')
    const sameSite = jevWrong.some((r) => {
      const s = scenarios.find((x) => x.id === r.id) as Scenario
      const owner = (id: string | null) => s.emails.find((e) => e.id === id)?.owner
      return r.picks.jev !== null && owner(r.picks.jev) === owner(s.correct)
    })
    if (sameSite) L.push('`selectByScores` takes the highest noul and uses recency only to break exact ties, so when an older resend of the same site scores equal to or slightly above the newest one, the older code is filled.', '')
  }
  L.push('## Jev latency and cost', '')
  L.push('| | p50 | p95 | max |')
  L.push('|---|---|---|---|')
  L.push(`| Per request (one message, final attempt) | ${ms(jevStats.requestLatencyMs.p50)} | ${ms(jevStats.requestLatencyMs.p95)} | ${ms(jevStats.requestLatencyMs.max)} |`)
  L.push(`| Per scenario (all 2-5 messages in parallel, wall clock) | ${ms(jevStats.scenarioLatencyMs.p50)} | ${ms(jevStats.scenarioLatencyMs.p95)} | ${ms(jevStats.scenarioLatencyMs.max)} |`)
  L.push('')
  L.push(`- Requests: ${calls.length} (${jevStats.failedRequests} failed after ${MAX_ATTEMPTS} attempts, ${retried} needed a retry on 429/529/network error).`)
  L.push(`- Requests slower than the production per-call timeout (${PROD_TIMEOUT_MS} ms, \`server/src/env.ts\`): ${overTimeout}; scenarios whose wall clock exceeded it: ${scenOverTimeout}. This run did not enforce the timeout; in production such a request would switch to the fallback rule.`)
  L.push(`- Tokens (from each response's \`usage\`): ${inTok} input, ${outTok} output; mean ${jevStats.meanInputTokensPerRequest.toFixed(0)} input tokens per request.`)
  L.push(`- Estimated cost: input tokens × $${USD_PER_MTOK}/MTok = $${costUsd.toFixed(6)} for the whole run, $${jevStats.estimatedCostUsdPerScenario.toFixed(8)} per scenario (one fill). Output tokens are free per the Jev pricing page, so they are not priced.`)
  L.push('- Latency is measured from this machine (client side, includes network round trip to the API), not from the deployed server.')
  L.push('')
  L.push('## Method', '')
  L.push('- **Dataset** (`eval/scenarios.json`, written by `eval/generate.ts`): synthetic, author-written emails from hand-crafted templates. Fictional brands on `.example` or invented domains (`.co.uk`, `.co.jp`, `*.vercel.app`), plus the project\'s own demo site `skipass-demo.vercel.app` (given the fictional brand "Acme" in these scenarios; its real sender domain replaced by a fictional relay). Not real user mail. Deterministic: codes from a PRNG seeded by the scenario id, fixed dates. Each scenario = the requesting site\'s host + 2-5 emails in the `FetchedMessage.judgeText` layout (From/To/Subject/Date, blank line, body), exactly one correct email or none. The ground truth is checked at generation time: it must equal the newest one-time-code email whose registrable domain is the requesting site\'s.')
  L.push('- **Scope**: every email in a scenario is assumed to have passed the iOS code extractor (only code-bearing messages reach the judge). Promo codes, order/invoice numbers and reference numbers therefore model extractor false positives. The extractor itself is not evaluated.')
  L.push('- **Baseline**: newest email that carries a code (all of them here), by the `Date:` header via the server\'s `messageTime`.')
  L.push('- **Heuristic**: `fallbackSelect(service, messages)` imported from `server/src/jev.ts` unchanged (newest email containing the registrable domain, private suffixes included; else newest). It never returns "nothing" when there is at least one email.')
  L.push(`- **Jev**: for each email, the exact production request body \`buildRequestBody(service, text)\` from \`server/src/jev.ts\` POSTed to \`${JEV_URL}\` (one Noul question per email, as \`judgeMessages\` does), then \`selectByScores\` (highest noul ≥ 0.5, ties → newest, none → fill nothing). Messages of one scenario are sent in parallel (≤ ${MAX_CONCURRENCY} in flight), scenarios sequentially; 429/529 are retried with exponential backoff (500 ms × 2^n + jitter, up to ${MAX_ATTEMPTS} attempts) as the Jev API docs advise. Per-email noul scores are in \`eval/results.json\`.`)
  L.push('- **Reproduce**: see `eval/README.md`. Jev is a remote model; a rerun can give slightly different scores and latencies.')
  L.push('')
  L.push('## Limitations', '')
  L.push('- Synthetic and small (64 scenarios, one author). The mix is deliberately weighted toward cases that break the simple rules (older target, promos, orders, look-alike sites); the accuracies are **not** an estimate of real-world fill accuracy, only a comparison of the strategies on these case types.')
  L.push('- Templates are uniform English/Japanese plain text; real mail has HTML-to-text noise, tracking links, longer footers, other languages and more than 5 recent emails.')
  L.push('- The heuristic and baseline never "fill nothing", so they fail every no-correct-email scenario by construction; the no-correct subset is small (8).')
  L.push('- One run, one day, one client location; Jev scores and latencies can drift between runs and model versions (the request uses the `jev-latest` alias).')
  L.push('- The production 3 s per-call timeout was not enforced (see the timeout counts above); the extractor and the iOS on-device fallback are out of scope.')
  L.push('')
  writeFileSync(join(HERE, 'RESULTS.md'), L.join('\n'))

  console.log('\n' + L.slice(0, 20).join('\n'))
  console.log(`\nwrote ${join(HERE, 'results.json')} and RESULTS.md (${((finishedAt.getTime() - startedAt.getTime()) / 1000).toFixed(1)} s)`)
}

await main()
