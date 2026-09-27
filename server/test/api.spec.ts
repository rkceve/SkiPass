import { describe, expect, it } from 'vitest'
import { JEV_URL, QUESTION_ID } from '../src/jev'
import { FREE_PLAN, PAID_PLANS } from '../src/plans'
import {
  RC_ENTITLEMENT_IDS,
  RC_SAMPLE_EXPIRES_AT,
  jevResponse,
  judgeText,
  rcActiveEntitlement,
  rcCustomerMissing,
  rcEntitlementList,
  rcList,
} from './fixtures'
import { RC_PROJECT, fakeFetch, hang, json, makeClient } from './helpers'

const RC_ENTITLEMENTS_URL = `https://api.revenuecat.com/v2/projects/${RC_PROJECT}/entitlements?limit=100`
const rcActiveUrl = (user: string) =>
  `https://api.revenuecat.com/v2/projects/${RC_PROJECT}/customers/${encodeURIComponent(user)}/active_entitlements`

/** RevenueCat v2 answers: the entitlement list, and `active` (or 404) for any customer. */
function rcResponse(url: string, active: unknown[] | 'missing'): Response {
  if (url === RC_ENTITLEMENTS_URL) return json(rcEntitlementList(RC_PROJECT))
  if (url.endsWith('/active_entitlements')) {
    if (active === 'missing') return json(rcCustomerMissing, 404)
    return json(rcList(new URL(url).pathname, active))
  }
  return json({ error: 'unexpected url' }, 500)
}

/** Active entitlement for the plan with lookup key `lookupKey`. */
const activeFor = (lookupKey: string, expiresAt: number | null) =>
  rcActiveEntitlement(RC_ENTITLEMENT_IDS[lookupKey], expiresAt)

const SERVICE = 'login.acme.co.uk'

// Realistic one-time-code emails in the FetchedMessage.judgeText layout.
const acmeMsg = {
  id: '6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127',
  text: judgeText({
    from: 'Acme <no-reply@acme.co.uk>',
    to: 'user@example.com',
    subject: 'Your Acme verification code',
    date: '2026-09-23T10:00:00Z',
    body: 'Your Acme verification code is 482913. It expires in 10 minutes.',
  }),
}
const globexMsg = {
  id: '6F9619FF-8B86-D011-B42D-00CF4FC964FF:4128',
  text: judgeText({
    from: 'Globex <security@globex.com>',
    to: 'user@example.com',
    subject: 'Sign-in code',
    date: '2026-09-23T10:01:00Z',
    body: 'Use 771204 to sign in to Globex.',
  }),
}

const SEPT = new Date('2026-09-23T12:00:00Z')
const fixedNow = (d: Date) => () => d

async function body(res: Response): Promise<any> {
  return res.json()
}

describe('auth', () => {
  it('rejects a missing app token with 401 unauthorized', async () => {
    const c = makeClient({ token: null })
    for (const res of [await c.usage(), await c.fill({ messageId: 'x' }), await c.judge({ service: null, messages: [acmeMsg] })]) {
      expect(res.status).toBe(401)
      expect(await body(res)).toEqual({ error: 'unauthorized' })
    }
  })

  it('rejects a wrong app token with 401', async () => {
    const c = makeClient({ token: 'test-app-tokeX' })
    const res = await c.usage()
    expect(res.status).toBe(401)
    expect(await body(res)).toEqual({ error: 'unauthorized' })
  })

  it('fails closed when APP_TOKEN is not configured', async () => {
    const c = makeClient({ bindings: { APP_TOKEN: undefined }, token: '' })
    expect((await c.usage()).status).toBe(401)
  })

  it('rejects a missing X-SkiPass-User header with 400', async () => {
    const c = makeClient({})
    const res = await c.raw('/v1/usage', { headers: { 'X-SkiPass-App-Token': 'test-app-token' } })
    expect(res.status).toBe(400)
    expect(await body(res)).toEqual({ error: 'invalid_request' })
  })
})

describe('GET /v1/usage', () => {
  it('reports the free plan in RevenueCat mock mode with resetsAt at the next UTC month', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    const res = await c.usage()
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({
      plan: 'free',
      used: 0,
      limit: FREE_PLAN.monthlyFillLimit,
      resetsAt: '2026-10-01T00:00:00Z',
    })
  })

  it('rolls resetsAt over the year boundary', async () => {
    const c = makeClient({ deps: { now: fixedNow(new Date('2026-12-31T23:59:59Z')) } })
    expect((await body(await c.usage())).resetsAt).toBe('2027-01-01T00:00:00Z')
  })
})

describe('quota', () => {
  const limit = FREE_PLAN.monthlyFillLimit

  async function fillTimes(c: ReturnType<typeof makeClient>, n: number) {
    for (let i = 0; i < n; i++) expect((await c.fill({ messageId: `m${i}` })).status).toBe(200)
  }

  it('counts one fill per POST /v1/fills and returns remaining', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    const res = await c.fill({ messageId: acmeMsg.id })
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({ remaining: limit - 1 })
    expect((await body(await c.usage())).used).toBe(1)
  })

  it('stores the count under usage:<appUserID>:<YYYY-MM>', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    await c.fill({ messageId: acmeMsg.id })
    expect(await c.bindings.USAGE!.get(`usage:${c.user}:2026-09`)).toBe('1')
  })

  it('at limit-1: judge and the last fill succeed, remaining reaches 0', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    await fillTimes(c, limit - 1)
    const j = await c.judge({ service: SERVICE, messages: [acmeMsg] })
    expect(j.status).toBe(200)
    expect((await body(j)).remaining).toBe(1)
    const f = await c.fill({ messageId: acmeMsg.id })
    expect(f.status).toBe(200)
    expect(await body(f)).toEqual({ remaining: 0 })
  })

  it('at limit: judge and fills return 402 and the count does not grow', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    await fillTimes(c, limit)
    const j = await c.judge({ service: SERVICE, messages: [acmeMsg] })
    expect(j.status).toBe(402)
    expect(await body(j)).toEqual({ error: 'quota_exhausted', remaining: 0 })
    const f = await c.fill({ messageId: acmeMsg.id })
    expect(f.status).toBe(402)
    expect(await body(f)).toEqual({ error: 'quota_exhausted', remaining: 0 })
    expect((await body(await c.usage())).used).toBe(limit)
  })

  it('judge does not count usage', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    for (let i = 0; i < 3; i++) expect((await c.judge({ service: SERVICE, messages: [acmeMsg] })).status).toBe(200)
    expect((await body(await c.usage())).used).toBe(0)
  })

  it('starts a fresh count in the next UTC month', async () => {
    let now = new Date('2026-09-30T23:59:59Z')
    const c = makeClient({ deps: { now: () => now } })
    await fillTimes(c, limit)
    expect((await c.judge({ service: SERVICE, messages: [acmeMsg] })).status).toBe(402)
    now = new Date('2026-10-01T00:00:00Z')
    expect(await body(await c.usage())).toEqual({
      plan: 'free',
      used: 0,
      limit,
      resetsAt: '2026-11-01T00:00:00Z',
    })
    expect((await c.judge({ service: SERVICE, messages: [acmeMsg] })).status).toBe(200)
  })
})

describe('POST /v1/judge — Jev mock mode', () => {
  it('scores the message naming the service 0.9 and chooses it', async () => {
    const c = makeClient({ deps: { now: fixedNow(SEPT) } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg, globexMsg] })
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({
      chosenId: acmeMsg.id,
      scores: { [acmeMsg.id]: 0.9, [globexMsg.id]: 0.1 },
      remaining: FREE_PLAN.monthlyFillLimit,
      source: 'jev',
    })
  })

  it('matches on the brand word alone', async () => {
    const c = makeClient({})
    const res = await c.judge({ service: 'https://www.globex.com/login', messages: [acmeMsg, globexMsg] })
    expect((await body(res)).chosenId).toBe(globexMsg.id)
  })

  it('returns chosenId null when nothing matches', async () => {
    const c = makeClient({})
    const res = await c.judge({ service: 'initech.com', messages: [acmeMsg, globexMsg] })
    expect(await body(res)).toMatchObject({ chosenId: null, source: 'jev' })
  })

  it('is used when JEV_MODE is live but no key is set', async () => {
    const f = fakeFetch(() => json({}, 500))
    const c = makeClient({ bindings: { JEV_MODE: 'live', JEV_API_KEY: '' }, deps: { fetch: f.fn } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg] })
    expect(await body(res)).toMatchObject({ chosenId: acmeMsg.id, source: 'jev' })
    expect(f.calls).toHaveLength(0)
  })
})

describe('POST /v1/judge — live Jev', () => {
  const live = { JEV_MODE: 'live', JEV_API_KEY: 'jev-test-key' }

  /** Answers each Jev call by looking up the noul for the message in the request `state`. */
  function jevByText(nouls: Map<string, number>) {
    return fakeFetch(async (url, init) => {
      expect(url).toBe(JEV_URL)
      const req = JSON.parse(String(init.body))
      return json(jevResponse(nouls.get(req.state) ?? 0))
    })
  }

  it('sends one Noul request per message with the contract wording', async () => {
    const f = jevByText(new Map([[acmeMsg.text, 0.97], [globexMsg.text, 0.2]]))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg, globexMsg] })
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({
      chosenId: acmeMsg.id,
      scores: { [acmeMsg.id]: 0.97, [globexMsg.id]: 0.2 },
      remaining: FREE_PLAN.monthlyFillLimit,
      source: 'jev',
    })
    expect(f.calls).toHaveLength(2)
    const call = f.calls.find((x) => JSON.parse(String(x.init.body)).state === acmeMsg.text)!
    expect(call.init.method).toBe('POST')
    const h = new Headers(call.init.headers)
    expect(h.get('Authorization')).toBe('Bearer jev-test-key')
    expect(h.get('Content-Type')).toBe('application/json')
    expect(JSON.parse(String(call.init.body))).toEqual({
      state: acmeMsg.text,
      model: 'jev-latest',
      questions: {
        [QUESTION_ID]: {
          type: 'noul',
          instructions:
            'Is this email delivering a one-time verification or sign-in code for the service at login.acme.co.uk?',
          criteria: {
            true: 'It delivers a one-time code for login.acme.co.uk',
            false: 'It is for another service, or it does not deliver a one-time code',
          },
        },
      },
    })
  })

  it('uses the service-less instructions when service is null', async () => {
    const f = jevByText(new Map([[acmeMsg.text, 0.9]]))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    await c.judge({ service: null, messages: [acmeMsg] })
    expect(JSON.parse(String(f.calls[0].init.body)).questions).toEqual({
      [QUESTION_ID]: {
        type: 'noul',
        instructions: 'Is this email delivering a one-time verification or sign-in code?',
      },
    })
  })

  it('breaks ties by the newest Date', async () => {
    const f = jevByText(new Map([[acmeMsg.text, 0.8], [globexMsg.text, 0.8]]))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    const res = await c.judge({ service: null, messages: [acmeMsg, globexMsg] })
    expect((await body(res)).chosenId).toBe(globexMsg.id) // 10:01 is newer than 10:00
  })

  it('accepts exactly 0.5 and rejects everything below it', async () => {
    const f1 = jevByText(new Map([[acmeMsg.text, 0.5]]))
    const r1 = await makeClient({ bindings: live, deps: { fetch: f1.fn } }).judge({ service: SERVICE, messages: [acmeMsg] })
    expect((await body(r1)).chosenId).toBe(acmeMsg.id)
    const f2 = jevByText(new Map([[acmeMsg.text, 0.49], [globexMsg.text, 0.1]]))
    const r2 = await makeClient({ bindings: live, deps: { fetch: f2.fn } }).judge({
      service: SERVICE,
      messages: [acmeMsg, globexMsg],
    })
    expect(await body(r2)).toMatchObject({ chosenId: null, source: 'jev', scores: { [acmeMsg.id]: 0.49 } })
  })

  it('falls back on timeout: newest message containing the registrable domain', async () => {
    const f = fakeFetch(hang)
    const c = makeClient({ bindings: live, deps: { fetch: f.fn, upstreamTimeoutMs: 20 } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg, globexMsg] })
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({
      chosenId: acmeMsg.id, // contains acme.co.uk although globexMsg is newer
      scores: {},
      remaining: FREE_PLAN.monthlyFillLimit,
      source: 'fallback',
    })
  })

  it('falls back on a Jev error status (529 overloaded) to the newest message when no domain matches', async () => {
    const f = fakeFetch(() => json({ error: 'overloaded' }, 529))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    const res = await c.judge({ service: 'initech.com', messages: [acmeMsg, globexMsg] })
    expect(await body(res)).toMatchObject({ chosenId: globexMsg.id, source: 'fallback' })
  })

  it('falls back when only one of the parallel calls fails', async () => {
    const f = fakeFetch(async (_, init) => {
      if (JSON.parse(String(init.body)).state === acmeMsg.text) return json(jevResponse(0.99))
      throw new TypeError('network')
    })
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg, globexMsg] })
    expect(await body(res)).toMatchObject({ chosenId: acmeMsg.id, source: 'fallback' })
  })

  it('falls back on a response without a numeric noul', async () => {
    const f = fakeFetch(() => json({ model: 'jev-1.13.0', answers: {}, usage: { input_tokens: 1, output_tokens: 0 } }))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn } })
    const res = await c.judge({ service: null, messages: [acmeMsg, globexMsg] })
    expect(await body(res)).toMatchObject({ chosenId: globexMsg.id, source: 'fallback' })
  })
})

describe('RevenueCat', () => {
  const live = { REVENUECAT_MODE: 'live', REVENUECAT_SECRET_KEY: 'sk_test_secret' }
  const rc = (active: unknown[] | 'missing') => fakeFetch((url) => rcResponse(url, active))

  it('calls the v2 entitlement list and active_entitlements with the secret key (id URL-encoded)', async () => {
    const f = rc([rcActiveEntitlement('entlc3d4e5f6a7', null)])
    const c = makeClient({ bindings: live, deps: { fetch: f.fn, now: fixedNow(SEPT) } })
    const res = await c.usage()
    // Only `premium` is active, which is not in plans.ts -> free.
    expect(await body(res)).toMatchObject({ plan: 'free', limit: FREE_PLAN.monthlyFillLimit })
    expect(f.calls.map((x) => x.url).sort()).toEqual([RC_ENTITLEMENTS_URL, rcActiveUrl(c.user)].sort())
    expect(rcActiveUrl(c.user)).toContain('%24RCAnonymousID%3A')
    for (const call of f.calls) {
      expect(call.init.method).toBe('GET')
      expect(new Headers(call.init.headers).get('Authorization')).toBe('Bearer sk_test_secret')
    }
  })

  it('maps an active (non-expiring) entitlement to its plan by lookup key', async () => {
    const pro = PAID_PLANS.find((p) => p.id === 'pro')!
    const c = makeClient({ bindings: live, deps: { fetch: rc([activeFor(pro.entitlementId!, null)]).fn } })
    expect(await body(await c.usage())).toMatchObject({ plan: 'pro', limit: pro.monthlyFillLimit })
  })

  it('prefers the higher tier when several entitlements are active', async () => {
    const c = makeClient({
      bindings: live,
      deps: { fetch: rc([activeFor('standard', null), activeFor('pro', null)]).fn },
    })
    expect((await body(await c.usage())).plan).toBe('pro')
  })

  it('treats a future expires_at as active and a past one as expired', async () => {
    const active = [activeFor('standard', RC_SAMPLE_EXPIRES_AT)]
    const before = makeClient({
      bindings: live,
      deps: { fetch: rc(active).fn, now: fixedNow(new Date('2022-07-21T00:00:00Z')) },
    })
    expect((await body(await before.usage())).plan).toBe('standard')
    const after = makeClient({
      bindings: live,
      deps: { fetch: rc(active).fn, now: fixedNow(new Date('2022-07-22T00:00:00Z')) },
    })
    expect((await body(await after.usage())).plan).toBe('free')
  })

  it('treats an unknown customer (404 resource_missing) as the free plan', async () => {
    const c = makeClient({ bindings: live, deps: { fetch: rc('missing').fn } })
    expect((await body(await c.usage())).plan).toBe('free')
  })

  it('uses the paid plan limit for quota checks', async () => {
    const standard = PAID_PLANS.find((p) => p.id === 'standard')!
    const c = makeClient({
      bindings: live,
      deps: { fetch: rc([activeFor('standard', null)]).fn, now: fixedNow(SEPT) },
    })
    expect(await body(await c.fill({ messageId: acmeMsg.id }))).toEqual({ remaining: standard.monthlyFillLimit - 1 })
  })

  it('caches the entitlement list between requests', async () => {
    const f = rc([activeFor('pro', null)])
    const c = makeClient({ bindings: live, deps: { fetch: f.fn, now: fixedNow(SEPT) } })
    await c.usage()
    await c.usage()
    expect(f.calls.filter((x) => x.url === RC_ENTITLEMENTS_URL)).toHaveLength(1)
    expect(f.calls.filter((x) => x.url.endsWith('/active_entitlements'))).toHaveLength(2)
  })

  it('degrades to the free plan on an upstream error', async () => {
    const c = makeClient({ bindings: live, deps: { fetch: fakeFetch(() => json({}, 500)).fn } })
    expect((await body(await c.usage())).plan).toBe('free')
  })

  it('does not call RevenueCat in mock mode, or without a project id', async () => {
    const f = rc([activeFor('pro', null)])
    const mock = makeClient({ bindings: { REVENUECAT_MODE: 'mock', REVENUECAT_SECRET_KEY: 'sk' }, deps: { fetch: f.fn } })
    expect((await body(await mock.usage())).plan).toBe('free')
    const noProject = makeClient({ bindings: { ...live, REVENUECAT_PROJECT_ID: '' }, deps: { fetch: f.fn } })
    expect((await body(await noProject.usage())).plan).toBe('free')
    expect(f.calls).toHaveLength(0)
  })
})

describe('POST /v1/judge — quota check and Jev run concurrently', () => {
  const live = {
    JEV_MODE: 'live',
    JEV_API_KEY: 'jev-test-key',
    REVENUECAT_MODE: 'live',
    REVENUECAT_SECRET_KEY: 'sk_test_secret',
  }

  it('starts the Jev calls without waiting for the RevenueCat lookup', async () => {
    const standard = PAID_PLANS.find((p) => p.id === 'standard')!
    // RevenueCat answers only once a Jev call has been issued. If the Jev calls waited for the
    // entitlement lookup, the lookup would time out and degrade to the free plan.
    let jevStarted!: () => void
    const jevCalled = new Promise<void>((resolve) => (jevStarted = resolve))
    const f = fakeFetch(async (url) => {
      if (url === JEV_URL) {
        jevStarted()
        return json(jevResponse(0.97))
      }
      await jevCalled
      return rcResponse(url, [activeFor(standard.entitlementId!, null)])
    })
    const c = makeClient({ bindings: live, deps: { fetch: f.fn, now: fixedNow(SEPT), upstreamTimeoutMs: 500 } })
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg] })
    expect(res.status).toBe(200)
    expect(await body(res)).toEqual({
      chosenId: acmeMsg.id,
      scores: { [acmeMsg.id]: 0.97 },
      remaining: standard.monthlyFillLimit,
      source: 'jev',
    })
  })

  it('returns 402 and discards the Jev result when the quota is exhausted', async () => {
    const f = fakeFetch((url) => (url === JEV_URL ? json(jevResponse(0.97)) : json({}, 500)))
    const c = makeClient({ bindings: live, deps: { fetch: f.fn, now: fixedNow(SEPT) } })
    for (let i = 0; i < FREE_PLAN.monthlyFillLimit; i++) {
      expect((await c.fill({ messageId: `m${i}` })).status).toBe(200)
    }
    const res = await c.judge({ service: SERVICE, messages: [acmeMsg] })
    expect(res.status).toBe(402)
    expect(await body(res)).toEqual({ error: 'quota_exhausted', remaining: 0 })
  })
})

describe('invalid bodies', () => {
  const bad = { error: 'invalid_request' }
  const cases: [string, unknown][] = [
    ['not JSON', '{"service":'],
    ['array body', '[]'],
    ['messages missing', { service: SERVICE }],
    ['messages empty', { service: SERVICE, messages: [] }],
    ['service is a number', { service: 42, messages: [acmeMsg] }],
    ['service missing', { messages: [acmeMsg] }],
    ['message without text', { service: SERVICE, messages: [{ id: 'a' }] }],
    ['message with empty id', { service: SERVICE, messages: [{ id: '', text: 'x' }] }],
    ['duplicate message ids', { service: SERVICE, messages: [acmeMsg, acmeMsg] }],
    ['too many messages', { service: SERVICE, messages: Array.from({ length: 51 }, (_, i) => ({ id: `m${i}`, text: 't' })) }],
  ]
  for (const [name, payload] of cases) {
    it(`judge: ${name} -> 400`, async () => {
      const res = await makeClient({}).judge(payload)
      expect(res.status).toBe(400)
      expect(await body(res)).toEqual(bad)
    })
  }

  for (const [name, payload] of [
    ['not JSON', 'nope'],
    ['messageId missing', {}],
    ['messageId not a string', { messageId: 7 }],
    ['messageId empty', { messageId: '' }],
  ] as [string, unknown][]) {
    it(`fills: ${name} -> 400 and nothing counted`, async () => {
      const c = makeClient({})
      const res = await c.fill(payload)
      expect(res.status).toBe(400)
      expect(await body(res)).toEqual(bad)
      expect((await body(await c.usage())).used).toBe(0)
    })
  }
})
