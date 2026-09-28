// Writes eval/scenarios.json from hand-written templates. Deterministic: no clock, no Math.random;
// codes come from a PRNG seeded by the scenario id, dates from a fixed base time.
//
// Everything here is SYNTHETIC and author-written: fictional brands on `.example` or invented
// domains (plus the project's own demo site skipass-demo.vercel.app). No real user mail was used.
//
// Every email in a scenario is assumed to have already passed the iOS code extractor (only
// code-bearing messages reach the judge, ios/Extension/Resolver/OneTimeCodeResolver.swift), so
// promo codes, order numbers etc. are modelled as extractor false positives that the judge sees.
//
// Usage: npx tsx generate.ts   (from eval/; writes scenarios.json next to this file)

import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { registrableDomain } from '../server/src/jev.ts'
import { CATEGORIES, type Category, type Kind, type Scenario, type ScenarioEmail } from './types.ts'

// ---------------------------------------------------------------------------------------------
// Deterministic helpers

function hash(s: string): number {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return h >>> 0
}

/** mulberry32 */
function rng(seed: number) {
  let a = seed
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const BASE_TIME = Date.parse('2026-09-20T09:00:00Z')

const iso = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')

// ---------------------------------------------------------------------------------------------
// Fictional brands

interface Brand {
  name: string
  /** Domain the brand's own mail is sent from. */
  mail: string
  /** Host used in links (defaults to `mail`). */
  web?: string
  lang?: 'en' | 'ja'
}

const B = {
  lumora: { name: 'Lumora', mail: 'lumora.example' },
  quill: { name: 'Quillfeather', mail: 'quillfeather.example' },
  bright: { name: 'Brightpine', mail: 'brightpine.example' },
  orbitly: { name: 'Orbitly', mail: 'orbitly.example' },
  veloxa: { name: 'Veloxa', mail: 'veloxa.example' },
  kestrel: { name: 'Kestrel Notes', mail: 'kestrelnotes.example' },
  marrow: { name: 'Marrowby', mail: 'marrowby.example' },
  halvard: { name: 'Halvard Air', mail: 'halvardair.example' },
  pebble: { name: 'Pebblecart', mail: 'pebblecart.example' },
  zentrik: { name: 'Zentrik', mail: 'zentrik.example' },
  ferro: { name: 'Ferroline', mail: 'ferroline.example' },
  cobalt: { name: 'Cobaltix', mail: 'cobaltix.example' },
  juniper: { name: 'Juniperly', mail: 'juniperly.example' },
  sable: { name: 'Sableworks', mail: 'sableworks.example' },
  trellium: { name: 'Trellium', mail: 'trellium.example' },
  nimbus: { name: 'Nimbusly', mail: 'nimbusly.example' },
  glimmer: { name: 'Glimmerly', mail: 'glimmerly.example' },
  rook: { name: 'Rookwise', mail: 'rookwise.example' },
  // Japanese-named fictional sites
  komorebi: { name: 'こもれびID', mail: 'komorebi-id.example', lang: 'ja' },
  hibari: { name: 'ひばりチケット', mail: 'hibari-ticket.example', lang: 'ja' },
  shizuku: { name: 'しずくクラウド', mail: 'shizuku-cloud.example', lang: 'ja' },
  kotonoha: { name: 'ことのは書店', mail: 'kotonoha-books.example', lang: 'ja' },
  tsumugi: { name: 'つむぎ証券', mail: 'tsumugi-sec.example', lang: 'ja' },
  hotaru: { name: 'ほたるモバイル', mail: 'hotaru-mobile.example', lang: 'ja' },
  // Subdomain / private-suffix sites
  wyndmoor: { name: 'Wyndmoor Bank', mail: 'wyndmoorbank.co.uk', web: 'login.wyndmoorbank.co.uk' },
  halsey: { name: 'Halsey Savings', mail: 'halseysavings.co.uk', web: 'online.halseysavings.co.uk' },
  orbitlyAcc: { name: 'Orbitly', mail: 'orbitly.example', web: 'accounts.orbitly.example' },
  ferroId: { name: 'Ferroline', mail: 'mail.ferroline.example', web: 'id.ferroline.example' },
  kotonohaJp: { name: 'ことのは書店', mail: 'kotonoha-books.co.jp', web: 'login.kotonoha-books.co.jp', lang: 'ja' },
  tallyfin: { name: 'Tallyfin', mail: 'relaykit.example', web: 'tallyfin-app.vercel.app' },
  pebbledash: { name: 'Pebbledash', mail: 'relaykit.example', web: 'pebbledash.vercel.app' },
  // The project's demo site host with the fictional brand "Acme", sent through a
  // provider. Real sender onboarding@resend.dev substituted by a fictional relay domain.
  demo: { name: 'Acme', mail: 'mailer-relay.example', web: 'skipass-demo.vercel.app' },
} satisfies Record<string, Brand>

const PROVIDERS = ['mg.postrelay.example', 'send.mailcrane.example', 'bounce.sendwave.example', 'notify.relaykit.example']

const TO_EN = 'Alex Morgan <alex.morgan@mailbox.example>'
const TO_JA = '佐藤 由衣 <sato.yui@mailbox.example>'

// ---------------------------------------------------------------------------------------------
// Email templates

/** How visible the brand's domain is in the email. */
type Show =
  | 'all' // From: brand domain, footer links to the brand domain
  | 'link' // From: a mail-provider domain, one link to the web host, no other domain mention
  | 'none' // From: a mail-provider domain, brand name only, no link

interface MailSpec {
  brand: Brand
  kind: Kind
  /** Template variant. */
  v: number
  /** Minutes after the scenario's base time. */
  min: number
  show?: Show
  /** Display name override (e.g. a parent company). */
  display?: string
  correct?: boolean
  /** Fixed code override (for the "code" of this email). */
  code?: string
}

interface Rendered {
  from: string
  subject: string
  body: string
  code: string
}

type Rand = () => number

function digits(r: Rand, n: number): string {
  let s = String(1 + Math.floor(r() * 9))
  while (s.length < n) s += String(Math.floor(r() * 10))
  return s
}

function alnum(r: Rand, n: number): string {
  const A = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let s = ''
  while (s.length < n) s += A[Math.floor(r() * A.length)]
  return s
}

function webHost(b: Brand) {
  return b.web ?? b.mail
}

function render(spec: MailSpec, r: Rand, providerIdx: number): Rendered {
  const b = spec.brand
  const show = spec.show ?? 'all'
  const ja = b.lang === 'ja'
  const provider = PROVIDERS[providerIdx % PROVIDERS.length]
  const senderDomain = show === 'all' ? b.mail : b.mail === 'relaykit.example' || b.mail === 'mailer-relay.example' ? b.mail : provider
  const local = spec.kind === 'otp' ? (ja ? 'no-reply' : ['no-reply', 'security', 'accounts', 'verify'][spec.v % 4]) : spec.kind === 'promo' ? 'news' : spec.kind === 'order' ? 'orders' : 'alerts'
  const display = spec.display ?? b.name
  const from = `${display} <${local}@${senderDomain}>`
  const host = webHost(b)
  const link = (path: string) => (show === 'none' ? '' : `https://${host}${path}`)
  const footer =
    show === 'all'
      ? ja
        ? `\n\n――――――――――\n${b.name} サポートセンター\nhttps://${host}/help\n※このメールは送信専用です。`
        : `\n\n--\n${b.name} · 2100 Harbor Street, Suite 400, Portland, OR 97201\nHelp: https://${host}/help · Privacy: https://${host}/privacy`
      : ja
        ? `\n\n――――――――――\n${b.name}\n※このメールは送信専用アドレスから配信しています。`
        : `\n\n--\nSent by ${display}. You received this email because of activity on your account.`

  if (spec.kind === 'otp') {
    const code = spec.code ?? (spec.v === 4 ? digits(r, 8) : digits(r, 6))
    if (ja) {
      switch (spec.v % 3) {
        case 0:
          return {
            from,
            code,
            subject: `【${b.name}】認証コードのお知らせ`,
            body:
              `${b.name}をご利用いただきありがとうございます。\n\nログイン用の認証コードは以下のとおりです。\n\n認証コード：${code}\n\n有効期限は発行から10分間です。\nこのメールに心当たりがない場合は、破棄してください。` +
              (show === 'link' ? `\n\nログイン画面：${link('/login')}` : '') +
              footer,
          }
        case 1:
          return {
            from,
            code,
            subject: 'ワンタイムパスワードのご案内',
            body:
              `佐藤 由衣 様\n\n${b.name}のワンタイムパスワードをお送りします。\n\nワンタイムパスワード：${code}\n\n画面に入力して手続きを完了してください（有効期限：5分）。\n第三者にこのパスワードを教えないでください。` +
              (show === 'link' ? `\n\n手続き画面はこちら：${link('/verify')}` : '') +
              footer,
          }
        default:
          return {
            from,
            code,
            subject: `${b.name} 確認コード: ${code}`,
            body:
              `確認コード ${code} を入力して、メールアドレスの確認を完了してください。\n\nこのコードの有効期限は15分です。` +
              (show === 'link' ? `\n${link('/confirm')}` : '') +
              footer,
          }
      }
    }
    switch (spec.v % 5) {
      case 0: // demo-style code email layout
        return {
          from,
          code,
          subject: `Your ${b.name} verification code is ${code}`,
          body:
            `Your ${b.name} verification code is ${code}.\n\nIt expires in 10 minutes.` +
            (show !== 'none' ? `\n\nEnter it at ${link('/')}` : '') +
            (show === 'all' ? footer : ''),
        }
      case 1:
        return {
          from,
          code,
          subject: `${b.name} sign-in code`,
          body:
            `Hi Alex,\n\nUse the code below to sign in to your ${b.name} account:\n\n    ${code}\n\nThis code expires in 15 minutes. If you didn't request it, you can safely ignore this email.` +
            (show === 'link' ? `\n\nSign in: ${link('/login')}` : '') +
            `\n\n— The ${b.name} team` +
            footer,
        }
      case 2:
        return {
          from,
          code,
          subject: `${code} is your ${b.name} login code`,
          body:
            `Enter ${code} to finish signing in.\n\nDon't share this code with anyone. ${b.name} will never ask you for it.\n\nRequested from Chrome on Windows near Toronto, ON.` +
            (show === 'link' ? `\nNot you? Secure your account: ${link('/security')}` : '') +
            footer,
        }
      case 3:
        return {
          from,
          code,
          subject: 'Confirm your email address',
          body:
            `Welcome to ${b.name}!\n\nYour confirmation code:\n${code}\n\nPaste it into the sign-up form to activate your account.` +
            (show === 'link' ? `\nOr open ${link('/confirm?session=' + alnum(r, 10).toLowerCase())}` : '') +
            footer,
        }
      default:
        return {
          from,
          code,
          subject: 'Your one-time passcode',
          body:
            `${b.name} one-time passcode: ${code}\n\nValid for 5 minutes. For your security, this passcode can only be used once.` +
            (show === 'link' ? `\n\nContinue at ${link('/mfa')}` : '') +
            footer,
        }
    }
  }

  if (spec.kind === 'promo') {
    if (ja) {
      const code = spec.code ?? `AKI${digits(r, 4)}`
      return {
        from,
        code,
        subject: `【${b.name}】週末限定クーポンのお届け`,
        body: `いつも${b.name}をご利用いただきありがとうございます。\n\n週末限定で使える500円OFFクーポンをお届けします。\n\nクーポンコード：${code}\n\nご注文手続きの画面で入力してください（10月5日まで）。\n${link('/campaign')}${footer}\n配信停止：${link('/mail-settings')}`,
      }
    }
    switch (spec.v % 3) {
      case 0: {
        const code = spec.code ?? `FALL${digits(r, 2)}`
        return {
          from,
          code,
          subject: `${b.name}: 20% off ends tonight`,
          body: `Last chance! Use code ${code} at checkout for 20% off your next order.\n\nShop the sale: ${link('/sale')}\n\nYou are receiving this because you subscribed to ${b.name} news.${footer}\nUnsubscribe: ${link('/unsubscribe')}`,
        }
      }
      case 1: {
        const code = spec.code ?? digits(r, 6)
        return {
          from,
          code,
          subject: `A gift for you from ${b.name}`,
          body: `Thanks for being with us, Alex.\n\nHere is your one-time discount code: ${code}\n\nValid for 7 days on orders over $30. One use per customer.\n${link('/offers')}${footer}\nUnsubscribe: ${link('/unsubscribe')}`,
        }
      }
      default: {
        const code = spec.code ?? `${alnum(r, 3)}-${digits(r, 3)}`
        return {
          from,
          code,
          subject: `Your ${b.name} referral reward is waiting`,
          body: `Share your code ${code} with friends. When they join, you both get $10 credit.\n\nInvite friends: ${link('/invite')}${footer}`,
        }
      }
    }
  }

  if (spec.kind === 'order') {
    if (ja) {
      const code = spec.code ?? `${digits(r, 6)}-${digits(r, 6)}`
      return {
        from,
        code,
        subject: `【${b.name}】ご注文ありがとうございます（注文番号：${code}）`,
        body: `佐藤 由衣 様\n\nこのたびは${b.name}をご利用いただき、誠にありがとうございます。\n以下の内容でご注文を承りました。\n\n注文番号：${code}\nご注文日：2026年9月20日\n合計金額：2,860円（税込）\n\nご注文履歴：${link('/orders')}${footer}`,
      }
    }
    switch (spec.v % 4) {
      case 0: {
        const code = spec.code ?? digits(r, 8)
        return {
          from,
          code,
          subject: `Order #${code} confirmed`,
          body: `Thanks for your order, Alex!\n\nOrder number: ${code}\n1 x Merino socks (grey, M)   $14.00\nShipping                    $4.20\nTotal                       $18.20\n\nTrack your order: ${link('/orders/' + code)}${footer}`,
        }
      }
      case 1: {
        const code = spec.code ?? digits(r, 6)
        return {
          from,
          code,
          subject: `Invoice INV-${code} from ${b.name}`,
          body: `Hello Alex,\n\nYour invoice INV-${code} is ready.\nAmount due: $42.00\nDue date: October 5, 2026\n\nView and pay: ${link('/billing/invoices')}${footer}`,
        }
      }
      case 2: {
        const code = spec.code ?? alnum(r, 6)
        return {
          from,
          code,
          subject: 'Your booking is confirmed',
          body: `Booking reference: ${code}\n\nPassenger: MORGAN/ALEX\nFlight HV 218  Toronto (YYZ) 14:05 → Montreal (YUL) 15:20\nSeat 14C\n\nManage booking: ${link('/manage')}${footer}`,
        }
      }
      default: {
        const code = spec.code ?? digits(r, 6)
        return {
          from,
          code,
          subject: 'Payment received',
          body: `We received your payment of $24.90.\n\nTransaction ID: ${code}\nCard ending 4417\n\nReceipt: ${link('/receipts')}${footer}`,
        }
      }
    }
  }

  // notice: security alert / account notice with a reference number
  const code = spec.code ?? digits(r, 6)
  if (ja) {
    return {
      from,
      code,
      subject: `【${b.name}】新しい端末からのログインがありました`,
      body: `新しい端末から${b.name}へのログインがありました。\n\n日時：2026年9月20日 18:04\n端末：iPhone（Safari）\n受付番号：${code}\n\nお心当たりがない場合はパスワードを変更してください。\n${link('/security')}${footer}`,
    }
  }
  return {
    from,
    code,
    subject: `New sign-in to your ${b.name} account`,
    body: `We noticed a new sign-in to your ${b.name} account from Safari on iPhone (Toronto, ON).\n\nReference: ${code}\n\nIf this was you, no action is needed. If not, reset your password: ${link('/security')}${footer}`,
  }
}

// ---------------------------------------------------------------------------------------------
// Scenario builder

const scenarios: Scenario[] = []

function S(category: Category, service: string, description: string, mails: MailSpec[]) {
  const n = scenarios.filter((s) => s.category === category).length + 1
  const id = `${category}-${String(n).padStart(2, '0')}`
  const r = rng(hash(id))
  const base = BASE_TIME + scenarios.length * 3600_000
  const sorted = [...mails].sort((a, b) => a.min - b.min)
  const correctCount = sorted.filter((m) => m.correct).length
  if (correctCount > 1) throw new Error(`${id}: more than one correct email`)
  const emails: ScenarioEmail[] = sorted.map((m, i) => {
    const out = render(m, r, hash(id) + i)
    const date = iso(base + m.min * 60_000)
    const to = m.brand.lang === 'ja' ? TO_JA : TO_EN
    return {
      id: `${id}-m${i + 1}`,
      from: out.from,
      to,
      subject: out.subject,
      date,
      body: out.body,
      text: `From: ${out.from}\nTo: ${to}\nSubject: ${out.subject}\nDate: ${date}\n\n${out.body}`,
      code: out.code,
      kind: m.kind,
      owner: registrableDomain(webHost(m.brand)) ?? webHost(m.brand),
    }
  })
  const ci = sorted.findIndex((m) => m.correct)
  // Ground truth must equal "newest OTP email whose owner is the requesting site's registrable domain".
  const site = registrableDomain(service)
  let expected = -1
  emails.forEach((e, i) => {
    if (e.kind === 'otp' && e.owner === site) expected = i
  })
  if (expected !== ci) throw new Error(`${id}: correct flag (${ci}) != newest target-site OTP (${expected})`)
  if (emails.length < 2 || emails.length > 5) throw new Error(`${id}: needs 2-5 emails`)
  scenarios.push({ id, category, description, service, emails, correct: ci < 0 ? null : emails[ci].id })
}

const otp = (brand: Brand, min: number, v: number, extra: Partial<MailSpec> = {}): MailSpec => ({ brand, kind: 'otp', v, min, ...extra })
const promo = (brand: Brand, min: number, v: number, extra: Partial<MailSpec> = {}): MailSpec => ({ brand, kind: 'promo', v, min, ...extra })
const order = (brand: Brand, min: number, v: number, extra: Partial<MailSpec> = {}): MailSpec => ({ brand, kind: 'order', v, min, ...extra })
const notice = (brand: Brand, min: number, extra: Partial<MailSpec> = {}): MailSpec => ({ brand, kind: 'notice', v: 0, min, ...extra })
const T = { correct: true } as const

// --- older_target: target code email is older than another site's code email -----------------
S('older_target', 'lumora.example', 'Lumora code 2 min before an Orbitly code', [otp(B.lumora, 0, 1, T), otp(B.orbitly, 2, 2)])
S('older_target', 'quillfeather.example', 'Quillfeather code, then Veloxa and Zentrik codes', [otp(B.quill, 0, 0, T), otp(B.veloxa, 1, 1), otp(B.zentrik, 3, 4)])
S('older_target', 'brightpine.example', 'Brightpine confirmation code, then Marrowby login code', [otp(B.bright, 0, 3, T), otp(B.marrow, 4, 2)])
S('older_target', 'kestrelnotes.example', 'Kestrel Notes code, then Cobaltix code 30 s later', [otp(B.kestrel, 0, 2, T), otp(B.cobalt, 0.5, 1)])
S('older_target', 'sableworks.example', 'Sableworks 8-digit passcode, then three other sites', [otp(B.sable, 0, 4, T), otp(B.juniper, 1, 0), otp(B.trellium, 2, 3), otp(B.nimbus, 5, 1)])
S('older_target', 'rookwise.example', 'Rookwise code, then Glimmerly code (same template)', [otp(B.rook, 0, 1, T), otp(B.glimmer, 1, 1)])
S('older_target', 'zentrik.example', 'Zentrik code, then Lumora and Pebblecart codes', [otp(B.zentrik, 0, 0, T), otp(B.lumora, 2, 3), otp(B.pebble, 3, 2)])

// --- brand_via_provider: target sent via provider domain, brand name only ----------------------
S('brand_via_provider', 'veloxa.example', 'Veloxa via provider, then Orbitly direct', [otp(B.veloxa, 0, 1, { show: 'none', ...T }), otp(B.orbitly, 2, 0)])
S('brand_via_provider', 'marrowby.example', 'Marrowby via provider, then Quillfeather via the same kind of provider', [otp(B.marrow, 0, 2, { show: 'none', ...T }), otp(B.quill, 1, 1, { show: 'none' })])
S('brand_via_provider', 'juniperly.example', 'Juniperly via provider is newest; older Brightpine code', [otp(B.bright, 0, 2), otp(B.juniper, 2, 0, { show: 'none', ...T })])
S('brand_via_provider', 'trellium.example', 'Trellium via provider, then Kestrel Notes and Sableworks', [otp(B.trellium, 0, 4, { show: 'none', ...T }), otp(B.kestrel, 1, 3), otp(B.sable, 2, 1)])
S('brand_via_provider', 'nimbusly.example', 'Nimbusly via provider between two other codes', [otp(B.cobalt, 0, 1), otp(B.nimbus, 1, 2, { show: 'none', ...T }), otp(B.glimmer, 3, 0, { show: 'none' })])
S('brand_via_provider', 'pebblecart.example', 'Pebblecart via provider, newest of three', [otp(B.rook, 0, 0), otp(B.lumora, 1, 1, { show: 'none' }), otp(B.pebble, 2, 3, { show: 'none', ...T })])
S('brand_via_provider', 'cobaltix.example', 'Cobaltix via provider, then Zentrik promo', [otp(B.cobalt, 0, 0, { show: 'none', ...T }), promo(B.zentrik, 1, 1)])

// --- domain_in_link_only: display name is a parent company, domain only in a link -------------
S('domain_in_link_only', 'glimmerly.example', 'Sent as "Northwind Media Group", link to glimmerly.example; newer Veloxa code', [otp(B.glimmer, 0, 1, { show: 'link', display: 'Northwind Media Group', ...T }), otp(B.veloxa, 2, 2)])
S('domain_in_link_only', 'skipass-demo.vercel.app', 'Demo site (brand Acme) with link only; newer Juniperly code', [otp(B.demo, 0, 0, { show: 'link', ...T }), otp(B.juniper, 1, 1)])
S('domain_in_link_only', 'orbitly.example', 'Sent as "Orbitly Accounts" via provider, link only; newer Trellium code', [otp(B.orbitly, 0, 2, { show: 'link', display: 'Orbitly Accounts', ...T }), otp(B.trellium, 1, 0)])
S('domain_in_link_only', 'halvardair.example', 'Sent as "HV Loyalty Club", link only; newer Marrowby code and older Rookwise code', [otp(B.rook, 0, 1), otp(B.halvard, 1, 3, { show: 'link', display: 'HV Loyalty Club', ...T }), otp(B.marrow, 3, 2)])
S('domain_in_link_only', 'sableworks.example', 'Sent as "SW Studio", link only, newest', [otp(B.nimbus, 0, 0), otp(B.sable, 2, 4, { show: 'link', display: 'SW Studio', ...T })])
S('domain_in_link_only', 'skipass-demo.vercel.app', 'Demo site link only; newer other code also sent via a relay', [otp(B.demo, 0, 0, { show: 'link', ...T }), otp(B.cobalt, 1, 0, { show: 'none' })])
S('domain_in_link_only', 'trellium.example', 'Sent as "Trell Inc.", link only; newer Glimmerly code via link', [otp(B.trellium, 0, 1, { show: 'link', display: 'Trell Inc.', ...T }), otp(B.glimmer, 2, 3, { show: 'link' })])

// --- same_site_two_codes: resend; newest from the target site is correct ------------------------
S('same_site_two_codes', 'lumora.example', 'Two Lumora codes (resend 1 min apart)', [otp(B.lumora, 0, 1), otp(B.lumora, 1, 1, T)])
S('same_site_two_codes', 'orbitly.example', 'Two Orbitly codes, then a newer Veloxa code', [otp(B.orbitly, 0, 2), otp(B.orbitly, 2, 2, T), otp(B.veloxa, 3, 1)])
S('same_site_two_codes', 'skipass-demo.vercel.app', 'Two demo-site codes (resend 30 s apart)', [otp(B.demo, 0, 0, { show: 'link' }), otp(B.demo, 0.5, 0, { show: 'link', ...T })])
S('same_site_two_codes', 'zentrik.example', 'Two Zentrik codes with different templates, newer Quillfeather code', [otp(B.zentrik, 0, 3), otp(B.zentrik, 3, 0, T), otp(B.quill, 4, 2)])
S('same_site_two_codes', 'brightpine.example', 'Three Brightpine codes (two resends)', [otp(B.bright, 0, 1), otp(B.bright, 1, 1), otp(B.bright, 2, 1, T)])
S('same_site_two_codes', 'kestrelnotes.example', 'Two Kestrel Notes codes via provider, other site in between', [otp(B.kestrel, 0, 2, { show: 'none' }), otp(B.marrow, 1, 0), otp(B.kestrel, 2, 2, { show: 'none', ...T })])
S('same_site_two_codes', 'pebblecart.example', 'Two Pebblecart codes, newer Pebblecart promo', [otp(B.pebble, 0, 4), otp(B.pebble, 1, 4, T), promo(B.pebble, 2, 1)])

// --- promo_codes -------------------------------------------------------------------------------
S('promo_codes', 'quillfeather.example', 'Quillfeather code, then its own 20%-off promo code', [otp(B.quill, 0, 1, T), promo(B.quill, 2, 0)])
S('promo_codes', 'veloxa.example', 'Veloxa code, then its own 6-digit "one-time discount code"', [otp(B.veloxa, 0, 2, T), promo(B.veloxa, 1, 1)])
S('promo_codes', 'juniperly.example', 'Juniperly code, then a referral code from Juniperly', [otp(B.juniper, 0, 0, T), promo(B.juniper, 3, 2)])
S('promo_codes', 'marrowby.example', 'Marrowby code, then a Nimbusly 6-digit discount code', [otp(B.marrow, 0, 3, T), promo(B.nimbus, 1, 1)])
S('promo_codes', 'rookwise.example', 'Rookwise code via provider, then Rookwise promo mentioning the domain', [otp(B.rook, 0, 1, { show: 'none', ...T }), promo(B.rook, 2, 1)])
S('promo_codes', 'cobaltix.example', 'Older Cobaltix promo, then Cobaltix code', [promo(B.cobalt, 0, 0), otp(B.cobalt, 5, 2, T)])
S('promo_codes', 'nimbusly.example', 'Nimbusly code, other-site promo, then Nimbusly promo', [otp(B.nimbus, 0, 0, T), promo(B.glimmer, 1, 2), promo(B.nimbus, 2, 1)])

// --- order_invoice_numbers ------------------------------------------------------------------------
S('order_invoice_numbers', 'pebblecart.example', 'Pebblecart code, then its own order confirmation', [otp(B.pebble, 0, 1, T), order(B.pebble, 2, 0)])
S('order_invoice_numbers', 'sableworks.example', 'Sableworks code, then a Sableworks invoice', [otp(B.sable, 0, 2, T), order(B.sable, 1, 1)])
S('order_invoice_numbers', 'halvardair.example', 'Halvard Air code, then its booking reference (6 alphanumerics)', [otp(B.halvard, 0, 0, T), order(B.halvard, 3, 2)])
S('order_invoice_numbers', 'glimmerly.example', 'Glimmerly code, then a Zentrik payment receipt', [otp(B.glimmer, 0, 3, T), order(B.zentrik, 1, 3)])
S('order_invoice_numbers', 'lumora.example', 'Lumora code via provider, then Lumora payment receipt', [otp(B.lumora, 0, 2, { show: 'none', ...T }), order(B.lumora, 1, 3)])
S('order_invoice_numbers', 'trellium.example', 'Older Trellium order, Trellium code, newer Brightpine invoice', [order(B.trellium, 0, 0), otp(B.trellium, 2, 1, T), order(B.bright, 3, 1)])
S('order_invoice_numbers', 'zentrik.example', 'Zentrik code, then Zentrik sign-in alert with a reference number', [otp(B.zentrik, 0, 4, T), notice(B.zentrik, 1)])

// --- japanese -------------------------------------------------------------------------------------
S('japanese', 'komorebi-id.example', 'こもれびID code, then ひばりチケット code', [otp(B.komorebi, 0, 0, T), otp(B.hibari, 2, 1)])
S('japanese', 'shizuku-cloud.example', 'しずくクラウド confirmation code is newest; older つむぎ証券 one-time password', [otp(B.tsumugi, 0, 1), otp(B.shizuku, 1, 2, T)])
S('japanese', 'kotonoha-books.example', 'ことのは書店 code, then its own coupon code', [otp(B.kotonoha, 0, 0, T), promo(B.kotonoha, 1, 0)])
S('japanese', 'hotaru-mobile.example', 'ほたるモバイル one-time password via provider, then its own order', [otp(B.hotaru, 0, 1, { show: 'none', ...T }), order(B.hotaru, 2, 0)])
S('japanese', 'tsumugi-sec.example', 'つむぎ証券 code, then English Orbitly code', [otp(B.tsumugi, 0, 1, T), otp(B.orbitly, 1, 2)])
S('japanese', 'hibari-ticket.example', 'ひばりチケット code (link only via provider), then こもれびID code and ひばり sign-in alert', [otp(B.hibari, 0, 2, { show: 'link', ...T }), otp(B.komorebi, 1, 0), notice(B.hibari, 2)])
S('japanese', 'komorebi-id.example', 'Two こもれびID codes (resend), then しずくクラウド code', [otp(B.komorebi, 0, 0), otp(B.komorebi, 1, 0, T), otp(B.shizuku, 2, 1)])

// --- subdomain_site ----------------------------------------------------------------------------
S('subdomain_site', 'login.wyndmoorbank.co.uk', 'login.<bank>.co.uk; bank code, then another .co.uk bank code', [otp(B.wyndmoor, 0, 1, T), otp(B.halsey, 2, 2)])
S('subdomain_site', 'online.halseysavings.co.uk', 'online.<bank>.co.uk; bank passcode is newest, older other bank code', [otp(B.wyndmoor, 0, 4), otp(B.halsey, 1, 4, T)])
S('subdomain_site', 'accounts.orbitly.example', 'accounts.orbitly.example; Orbitly code, then Lumora code', [otp(B.orbitlyAcc, 0, 2, T), otp(B.lumora, 1, 1)])
S('subdomain_site', 'id.ferroline.example', 'id.ferroline.example; code from mail.ferroline.example, then Kestrel code', [otp(B.ferroId, 0, 0, T), otp(B.kestrel, 3, 0)])
S('subdomain_site', 'tallyfin-app.vercel.app', '*.vercel.app: Tallyfin link-only code, newer Pebbledash (another vercel.app app) code', [otp(B.tallyfin, 0, 1, { show: 'link', ...T }), otp(B.pebbledash, 1, 1, { show: 'link' })])
S('subdomain_site', 'skipass-demo.vercel.app', 'Demo site vercel.app code, newer Tallyfin vercel.app code', [otp(B.demo, 0, 0, { show: 'link', ...T }), otp(B.tallyfin, 1, 2, { show: 'link' })])
S('subdomain_site', 'login.kotonoha-books.co.jp', 'login.<x>.co.jp Japanese code, then ほたるモバイル code', [otp(B.kotonohaJp, 0, 0, T), otp(B.hotaru, 1, 2)])

// --- no_correct ------------------------------------------------------------------------------------
S('no_correct', 'lumora.example', 'Only other sites\' codes (Orbitly, Veloxa)', [otp(B.orbitly, 0, 1), otp(B.veloxa, 2, 0)])
S('no_correct', 'quillfeather.example', 'Quillfeather promo code and a Zentrik code', [promo(B.quill, 0, 1), otp(B.zentrik, 1, 2)])
S('no_correct', 'pebblecart.example', 'Pebblecart order number and a Rookwise code', [otp(B.rook, 0, 3), order(B.pebble, 1, 0)])
S('no_correct', 'brightpine.example', 'Brightpine sign-in alert (reference number) and a Glimmerly promo', [promo(B.glimmer, 0, 0), notice(B.bright, 1)])
S('no_correct', 'kotonoha-books.example', 'ことのは書店 coupon and こもれびID code', [otp(B.komorebi, 0, 0), promo(B.kotonoha, 1, 0)])
S('no_correct', 'skipass-demo.vercel.app', 'Only other vercel.app apps\' codes (Tallyfin, Pebbledash)', [otp(B.tallyfin, 0, 0, { show: 'link' }), otp(B.pebbledash, 1, 3, { show: 'link' })])
S('no_correct', 'login.wyndmoorbank.co.uk', 'Only the other .co.uk bank\'s passcodes', [otp(B.halsey, 0, 4), otp(B.halsey, 1, 4)])
S('no_correct', 'sableworks.example', 'Sableworks invoice and referral code, Nimbusly code', [order(B.sable, 0, 1), otp(B.nimbus, 1, 1), promo(B.sable, 2, 2)])

// ---------------------------------------------------------------------------------------------

const out = join(dirname(fileURLToPath(import.meta.url)), 'scenarios.json')
writeFileSync(
  out,
  JSON.stringify(
    {
      generatedBy: 'eval/generate.ts',
      note: 'Synthetic, author-written scenarios with fictional brands/domains (plus the demo site skipass-demo.vercel.app). Not real user mail.',
      count: scenarios.length,
      scenarios,
    },
    null,
    2,
  ) + '\n',
)
const byCat = CATEGORIES.map((c) => `${c}=${scenarios.filter((s) => s.category === c).length}`).join(' ')
console.log(`wrote ${scenarios.length} scenarios to ${out}\n${byCat}`)
