# Third-party notices

SkiPass is released under the [MIT License](LICENSE). It contains or is derived from the third-party material listed below, and it depends on the packages listed under "Dependencies", which are downloaded at build time and are not committed to this repository.

## Code and data included in this repository

### 2FHey (TwoFHey) — CC0-1.0

- Source: https://github.com/SoFriendly/2fhey, commit `76a3c02df52ea98bba5263233ec337823310df07`
- Used in: `ios/SkiPassCore/Sources/SkiPassExtraction/`
  - `OTPParser.swift`: a Swift port of `TwoFHey/OTPParser/OTPParser.swift`, with macOS-only parts and the runtime pattern download removed and email-specific additions marked in the file.
  - `Resources/*.json`: the pattern files from `TwoFHey/OTPKeywords/`, copied unmodified, except `Resources/ja.json`, which is written for SkiPass and is not part of 2FHey.
- Full license text: [`ios/SkiPassCore/Sources/SkiPassExtraction/Resources/THIRD_PARTY_2FHEY.txt`](ios/SkiPassCore/Sources/SkiPassExtraction/Resources/THIRD_PARTY_2FHEY.txt)

### Public Suffix List (derived data) — MPL-2.0

- Source: https://publicsuffix.org/list/, as bundled in tldts 7.4.15
- Used in: `ios/Extension/Identity/PublicSuffixes.swift`, a table of two-label public suffixes generated with tldts so that the extension computes registrable domains the same way as the server.

## Dependencies (resolved at build time)

### iOS app and extension (Swift Package Manager)

| Package | Version | License |
|---|---|---|
| [SwiftMail](https://github.com/Cocoanetics/SwiftMail) | 1.12.0 | BSD-2-Clause |
| [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) | 3.0.0 | Apache-2.0 |
| [RevenueCat purchases-ios](https://github.com/RevenueCat/purchases-ios) | 5.91.0 | MIT |

Packages that SwiftMail's library target depends on:

| Package | License |
|---|---|
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 |
| [swift-nio-imap](https://github.com/apple/swift-nio-imap) | Apache-2.0 |
| [swift-nio-ssl](https://github.com/apple/swift-nio-ssl) (includes BoringSSL; see that package's license files) | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | Apache-2.0 |
| [SwiftCross](https://github.com/Cocoanetics/SwiftCross) | MIT |

### Server (npm, runtime)

| Package | Version | License |
|---|---|---|
| [hono](https://github.com/honojs/hono) | 4.13.8 | MIT |
| [tldts](https://github.com/remusao/tldts) (with tldts-core) | 7.4.15 | MIT |

Development-only npm packages (TypeScript, Vitest, Wrangler and their dependencies) are listed with their licenses in `server/package-lock.json`, `demo-web/package-lock.json` and `eval/package-lock.json`.

### Loaded at runtime, not bundled

- The demo site (`demo-web/public/`) loads the Atkinson Hyperlegible and Zilla Slab fonts from Google Fonts (SIL Open Font License 1.1).
- The `live-sim` workflow downloads serve-sim (EvanBacon/serve-sim, Apache-2.0) on the CI runner.

## Services

Jev (TypeSafe), RevenueCat, Resend, Upstash, Vercel, Google and Microsoft sign-in are used through their public APIs under their own terms of service. No code from these services is included beyond the SDKs listed above.
