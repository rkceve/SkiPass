# eval: which code email gets filled

Compares three ways of choosing the one-time-code email for a sign-in when several code-bearing
emails are in the inbox:

1. **Newest code** (baseline): the newest email that carries a code.
2. **Domain heuristic**: the server's fallback rule `fallbackSelect` (`server/src/jev.ts`).
3. **Jev**: the server's per-email Noul question (`buildRequestBody` / `buildQuestion`) sent to the
   real Jev API, then the server's `selectByScores`.

All three import the production code from `../server/src/jev.ts`; nothing is re-implemented except
the trivial baseline. Results: [`RESULTS.md`](RESULTS.md) (summary) and `results.json` (per-email
scores, latencies, token usage).

## Files

| File | What |
|---|---|
| `generate.ts` | Writes `scenarios.json` from hand-written templates (deterministic) |
| `scenarios.json` | 64 synthetic scenarios: requesting site + 2-5 emails in `FetchedMessage.judgeText` layout, one correct email or none |
| `run.ts` | Runs the three strategies, writes `results.json` and `RESULTS.md` |
| `types.ts` | Shared types and category descriptions |

The dataset is **synthetic and author-written** (fictional brands on `.example` or invented
domains, plus the demo site `skipass-demo.vercel.app`); it contains no real user mail.

## Reproduce

Needs Node 22+ and the server's dependencies (`jev.ts` imports `tldts`).

```sh
npm ci --prefix server
npm ci --prefix eval

cd eval
npx tsx generate.ts                    # optional: rebuilds scenarios.json (byte-identical)
npx tsx run.ts --dry                   # no Jev calls: baseline + heuristic only, prints, writes nothing
JEV_API_KEY=... npx tsx run.ts         # real run: calls Jev, overwrites results.json and RESULTS.md
```

From the repo root the same works as `JEV_API_KEY=... npx tsx eval/run.ts` once `tsx` is
available (e.g. `npm i -g tsx`); paths are resolved relative to the script.
`JEV_API_KEY_FILE=<path to a file containing only the key>` can be used instead of `JEV_API_KEY`.
The key is only sent in the `Authorization` header and never written to any output.

A real run sends one request per email (146 for the current dataset), at most 5 in flight,
retrying HTTP 429/529 with exponential backoff as the Jev API docs advise. Cost is a fraction of a
cent. Jev is a remote model behind the `jev-latest` alias, so reruns can differ slightly.

Observed on 2026-09-27 (`jev-1.13.0`): two consecutive full runs both scored Jev 62/64, but the two
misses moved within `same_site_two_codes` (first run: `-05` and `-06`; second, committed run:
`-01` and `-02`). In those scenarios the resent codes of one site score within ~0.01 of each other,
and `selectByScores` picks the highest score rather than the newest, so which resend wins is noise.
