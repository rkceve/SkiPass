import AuthenticationServices
import XCTest
import SkiPassModels

// Tests for identity registration inputs (ios/Extension/Identity) and the local judge fallback
// (ios/Extension/Resolver/LocalFallbackJudge.swift). Both are compiled into this test bundle.

final class EmailDomainsTests: XCTestCase {

    func testRegistrableDomainMirrorsServerRule() {
        XCTAssertEqual(EmailDomains.registrableDomain("accounts.google.com"), "google.com")
        XCTAssertEqual(EmailDomains.registrableDomain("https://www.bbc.co.uk/account/signin"), "bbc.co.uk")
        XCTAssertEqual(EmailDomains.registrableDomain("login.rakuten.co.jp"), "rakuten.co.jp")
        XCTAssertEqual(EmailDomains.registrableDomain("Example.COM:443"), "example.com")
        XCTAssertEqual(EmailDomains.registrableDomain("github.com"), "github.com")
        // The server uses tldts with allowPrivateDomains, so a vercel.app site keeps its own name.
        XCTAssertEqual(EmailDomains.registrableDomain("skipass-demo.vercel.app"), "skipass-demo.vercel.app")
        XCTAssertEqual(EmailDomains.registrableDomain("login.leumi.co.il"), "leumi.co.il")
        XCTAssertNil(EmailDomains.registrableDomain("  "))
    }

    /// Every case in registrable-domain-parity.json was produced by the server's
    /// rule (tldts, allowPrivateDomains: true) and must come out the same here.
    func testRegistrableDomainMatchesServerForParityCases() throws {
        let url = try XCTUnwrap(Bundle(for: EmailDomainsTests.self).url(forResource: "registrable-domain-parity",
                                                                        withExtension: "json"))
        let file = try JSONDecoder().decode(ParityFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(file.cases.count, 200)
        for testCase in file.cases {
            XCTAssertEqual(EmailDomains.registrableDomain(testCase.input), testCase.expected, testCase.input)
        }
    }

    private struct ParityFile: Decodable {
        struct Case: Decodable {
            let input: String
            let expected: String?
        }
        let cases: [Case]
    }

    func testMailAndTrackingDomainsAreNotServiceDomains() {
        let message = FetchedMessage(
            id: "m:3", mailboxAddress: "me@gmail.com",
            from: "Acme <bounce-123@em1234.sendgrid.net>", to: "me@gmail.com",
            subject: "Your Acme code", date: Date(timeIntervalSince1970: 1_790_000_000),
            bodyText: "Your Acme code is 123456.\nSign in at https://login.acme.com/\n"
                + "Unsubscribe: https://acme.us1.list-manage.com/unsubscribe?u=1\n"
                + "Tracking: https://u123.ct.sendgrid.net/ls/click?upn=abc\n"
                + "Questions? Write to acme.support@gmail.com or https://mandrillapp.com/track/click/1"
        )
        XCTAssertEqual(EmailDomains.domains(in: message), ["acme.com"])
    }

    func testDomainsInVerificationEmailComeFromSenderAndLinks() {
        let message = FetchedMessage(
            id: "m:1", mailboxAddress: "me@gmail.com",
            from: "Acme Login <no-reply@mail.acme.com>", to: "me@gmail.com",
            subject: "Your code", date: Date(timeIntervalSince1970: 1_790_000_000),
            bodyText: "Your code is 123456. Enter it at https://login.acme.com/verify?x=1\n"
                + "Unsubscribe: http://click.mailer.example.net/u/abc, or mailto:help@acme.com"
        )
        XCTAssertEqual(EmailDomains.domains(in: message), ["acme.com", "example.net"])
    }

    func testDemoEmailYieldsTheDemoDomainFamily() {
        // Layout of a demo verification email (links to the demo site on skipass-demo.vercel.app).
        let message = FetchedMessage(
            id: "m:2", mailboxAddress: "me@gmail.com",
            from: "SkiPass Demo <onboarding@resend.dev>", to: "me@gmail.com",
            subject: "Your SkiPass Demo verification code is 482913",
            date: Date(timeIntervalSince1970: 1_790_000_000),
            bodyText: "Your SkiPass Demo verification code is 482913.\n\nIt expires in 10 minutes.\n\n"
                + "Enter it at https://skipass-demo.vercel.app/"
        )
        // resend.dev is the sending provider, not the site (denylist).
        XCTAssertEqual(EmailDomains.domains(in: message), ["skipass-demo.vercel.app"])
    }

    func testPlausibleDomain() {
        XCTAssertTrue(EmailDomains.isPlausibleDomain("acme.com"))
        XCTAssertTrue(EmailDomains.isPlausibleDomain("skipass-demo.vercel.app"))
        XCTAssertFalse(EmailDomains.isPlausibleDomain("localhost"))
        XCTAssertFalse(EmailDomains.isPlausibleDomain("10.0.0.1"))
        XCTAssertFalse(EmailDomains.isPlausibleDomain("a..com"))
        XCTAssertFalse(EmailDomains.isPlausibleDomain("a b.com"))
    }
}

final class DomainSourcesTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "skipass.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testBundledListIsPresentAndWellFormed() {
        let domains = BundledDomainSource.load(from: Bundle(for: DomainSourcesTests.self))
        XCTAssertGreaterThanOrEqual(domains.count, 100)
        XCTAssertEqual(Set(domains).count, domains.count, "duplicates in sign-in-domains.json")
        XCTAssertTrue(domains.contains("google.com"))
        for domain in domains {
            XCTAssertTrue(EmailDomains.isPlausibleDomain(domain), domain)
            XCTAssertEqual(EmailDomains.registrableDomain(domain), domain, "not a registrable domain: \(domain)")
        }
    }

    func testStandardSourceHasDemoBundledAndSeenDomainsWithoutDuplicates() async {
        let seen = SeenDomainStore(defaults: freshDefaults())
        seen.record(["acme.com", "google.com"])
        let source = CompositeDomainSource.standard(bundle: Bundle(for: DomainSourcesTests.self), seen: seen)

        let domains = await source.domains()

        XCTAssertEqual(domains.first, DemoSite.domain)
        XCTAssertTrue(domains.contains("skipass-demo.vercel.app"))
        XCTAssertTrue(domains.contains("acme.com"))
        XCTAssertEqual(domains.filter { $0 == "google.com" }.count, 1)
        XCTAssertEqual(Set(domains).count, domains.count)
    }

    func testSeenStoreRecordsNewestFirstAndReportsChanges() {
        let store = SeenDomainStore(defaults: freshDefaults())

        XCTAssertTrue(store.record(["acme.com", "BETA.com"]))
        XCTAssertEqual(store.stored(), ["acme.com", "beta.com"])
        XCTAssertFalse(store.record(["beta.com"]), "same set of domains")
        XCTAssertEqual(store.stored(), ["beta.com", "acme.com"])
        XCTAssertFalse(store.record(["not a domain", "localhost"]))
        XCTAssertTrue(store.record(["gamma.org"]))
        XCTAssertEqual(store.stored(), ["gamma.org", "beta.com", "acme.com"])
    }

    func testSeenStoreSkipsMailProviders() {
        let store = SeenDomainStore(defaults: freshDefaults())
        XCTAssertFalse(store.record(["resend.dev", "gmail.com", "SendGrid.net", "amazonses.com"]))
        XCTAssertTrue(store.record(["acme.com", "outlook.com", "icloud.com"]))
        XCTAssertEqual(store.stored(), ["acme.com"])
    }

    func testSeenStoreIsCapped() {
        let store = SeenDomainStore(defaults: freshDefaults())
        store.record((0..<(SeenDomainStore.limit + 20)).map { "d\($0).com" })
        XCTAssertEqual(store.stored().count, SeenDomainStore.limit)
    }
}

final class IdentityRegistrarTests: XCTestCase {

    func testOneIdentityPerDomainLabelledWithFirstMailbox() {
        let identities = IdentityRegistrar.identities(
            domains: ["b.com", "A.com", "a.com", "https://c.co.uk/x", "", "bad"],
            mailboxAddresses: ["first@gmail.com", "second@outlook.com"])

        XCTAssertEqual(identities.map(\.serviceIdentifier.identifier), ["a.com", "b.com", "c.co.uk"])
        XCTAssertTrue(identities.allSatisfy { $0.serviceIdentifier.type == .domain })
        XCTAssertTrue(identities.allSatisfy { $0.label == "From first@gmail.com" })
        XCTAssertEqual(identities.map { $0.recordIdentifier ?? "" }, ["otp.a.com", "otp.b.com", "otp.c.co.uk"])
    }

    func testNoMailboxMeansNoIdentities() {
        XCTAssertTrue(IdentityRegistrar.identities(domains: ["a.com"], mailboxAddresses: []).isEmpty)
    }
}

final class LocalFallbackJudgeTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ id: String, body: String, from: String = "no-reply@mailer.example",
                         ageSeconds: TimeInterval) -> FetchedMessage {
        FetchedMessage(id: id, mailboxAddress: "me@gmail.com", from: from, to: "me@gmail.com",
                       subject: "Your code", date: Self.now.addingTimeInterval(-ageSeconds), bodyText: body)
    }

    func testNewestMessageMentioningTheServiceDomainWins() {
        let demoOld = message("1", body: "Code 111111 https://skipass-demo.vercel.app/", ageSeconds: 300)
        let demoNew = message("2", body: "Code 222222 https://skipass-demo.vercel.app/", ageSeconds: 60)
        let other = message("3", body: "Code 333333 for acme.com", ageSeconds: 10)

        XCTAssertEqual(LocalFallbackJudge.select(service: "skipass-demo.vercel.app",
                                                 messages: [demoOld, other, demoNew]), "2")
    }

    func testMatchesHeadersToo() {
        let fromAcme = message("1", body: "Code 111111", from: "Acme <no-reply@acme.com>", ageSeconds: 300)
        let newer = message("2", body: "Code 222222", ageSeconds: 10)
        XCTAssertEqual(LocalFallbackJudge.select(service: "https://login.acme.com/", messages: [fromAcme, newer]), "1")
    }

    func testWithoutMatchOrServiceTheNewestMessageWins() {
        let older = message("1", body: "Code 111111", ageSeconds: 300)
        let newer = message("2", body: "Code 222222", ageSeconds: 10)
        XCTAssertEqual(LocalFallbackJudge.select(service: "nomatch.com", messages: [older, newer]), "2")
        XCTAssertEqual(LocalFallbackJudge.select(service: nil, messages: [older, newer]), "2")
        XCTAssertNil(LocalFallbackJudge.select(service: nil, messages: []))
    }

    func testEqualDatesKeepTheFirstMessage() {
        let a = message("a", body: "acme.com 1", ageSeconds: 60)
        let b = message("b", body: "acme.com 2", ageSeconds: 60)
        XCTAssertEqual(LocalFallbackJudge.select(service: "acme.com", messages: [a, b]), "a")
    }

    func testFallbackJudgeUsesLocalRuleWhenServerFails() async throws {
        let m = message("1", body: "skipass-demo.vercel.app 123456", ageSeconds: 60)
        let judge = FallbackJudge(primary: StubJudge(result: .failure(URLError(.cannotConnectToHost))))
        let outcome = try await judge.judge(service: "skipass-demo.vercel.app", messages: [m])
        XCTAssertEqual(outcome, .chosen(messageID: "1", scores: [:]))
    }

    func testFallbackJudgeUsesLocalRuleWithoutServer() async throws {
        let m = message("1", body: "123456", ageSeconds: 60)
        let outcome = try await FallbackJudge(primary: nil).judge(service: nil, messages: [m])
        XCTAssertEqual(outcome, .chosen(messageID: "1", scores: [:]))
    }

    func testServerAnswersAreFinal() async throws {
        let m = message("1", body: "123456", ageSeconds: 60)
        let quota = try await FallbackJudge(primary: StubJudge(result: .success(.quotaExhausted)))
            .judge(service: nil, messages: [m])
        XCTAssertEqual(quota, .quotaExhausted)
        let none = try await FallbackJudge(primary: StubJudge(result: .success(.noMatch(scores: ["1": 0.1]))))
            .judge(service: nil, messages: [m])
        XCTAssertEqual(none, .noMatch(scores: ["1": 0.1]))
    }

    /// A server reply naming a message that was not sent is a bad reply, so the local rule runs.
    func testFallbackJudgeUsesLocalRuleWhenServerChoosesUnknownMessage() async throws {
        let m = message("1", body: "skipass-demo.vercel.app 123456", ageSeconds: 60)
        let judge = FallbackJudge(primary: StubJudge(result: .success(.chosen(messageID: "other:9", scores: [:]))))
        let outcome = try await judge.judge(service: "skipass-demo.vercel.app", messages: [m])
        XCTAssertEqual(outcome, .chosen(messageID: "1", scores: [:]))
    }

    func testResolverFillsFromLocalRuleWhenServerIsDownAndReportsChosenMessage() async {
        let box = MailboxConfig(address: "me@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                imapPort: 993, username: "me@gmail.com")
        let demo = message("\(box.id):1", body: "CODE:482913 https://skipass-demo.vercel.app/", ageSeconds: 120)
        let newerOther = message("\(box.id):2", body: "CODE:999999 for acme.com", ageSeconds: 30)
        let observed = Observed()
        let resolver = OneTimeCodeResolver(
            mailboxes: { [box] },
            fetcher: StubFetcher(messages: [demo, newerOther]),
            extractor: PrefixExtractor(),
            judge: FallbackJudge(primary: StubJudge(result: .failure(URLError(.timedOut)))),
            usage: StubUsage(),
            now: { LocalFallbackJudgeTests.now },
            chosenObserver: { observed.set([$0.id]) }
        )

        let resolved = await resolver.resolve(service: "skipass-demo.vercel.app")

        XCTAssertEqual(resolved, ResolvedCode(code: "482913", messageID: demo.id))
        // Only the message that was actually used records its domains.
        XCTAssertEqual(observed.get(), [demo.id])
    }
}

// MARK: - Fakes (names distinct from OneTimeCodeResolverTests' private fakes)

private struct StubJudge: CandidateJudging {
    let result: Result<JudgeOutcome, URLError>

    func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome {
        try result.get()
    }
}

private struct StubFetcher: MailFetching {
    let messages: [FetchedMessage]

    func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage] {
        messages
    }
}

/// Extracts the six characters after "CODE:" (test-only format).
private struct PrefixExtractor: CodeExtracting {
    func extractCode(from message: FetchedMessage) -> String? {
        guard let range = message.bodyText.range(of: "CODE:") else { return nil }
        return String(message.bodyText[range.upperBound...].prefix(6))
    }
}

private struct StubUsage: UsageReporting {
    func reportFill(messageID: String) async throws -> Int { 0 }
    func currentUsage() async throws -> UsageSnapshot {
        UsageSnapshot(plan: "free", used: 0, limit: 10, resetsAt: Date(timeIntervalSince1970: 0))
    }
}

private final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func set(_ value: [String]) {
        lock.lock()
        ids = value
        lock.unlock()
    }

    func get() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}
