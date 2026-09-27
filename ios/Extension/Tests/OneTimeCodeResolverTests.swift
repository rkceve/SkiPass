import XCTest
import SkiPassModels

// Unit tests for OneTimeCodeResolver (CONTRACTS §6). The resolver depends only on
// SkiPassModels protocols, so every collaborator here is a fake.

final class OneTimeCodeResolverTests: XCTestCase {

    // MARK: - Fixtures

    private static let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
    private var now: Date { Self.fixedNow }

    private func mailbox(_ address: String) -> MailboxConfig {
        MailboxConfig(address: address, kind: .imap, imapHost: "imap.example.com",
                      imapPort: 993, username: address)
    }

    private func message(_ id: String, _ mailbox: MailboxConfig, body: String,
                         ageSeconds: TimeInterval = 60) -> FetchedMessage {
        FetchedMessage(id: id, mailboxAddress: mailbox.address, from: "no-reply@acme.example.com",
                       to: mailbox.address, subject: "Your code", date: now.addingTimeInterval(-ageSeconds),
                       bodyText: body)
    }

    private func makeResolver(mailboxes: [MailboxConfig],
                              fetcher: FakeFetcher,
                              judge: FakeJudge,
                              usage: FakeUsage = FakeUsage(),
                              budget: Duration = .seconds(4),
                              retry: FillReportRetry = FillReportRetry(delays: [.milliseconds(10)]),
                              chosenObserver: (@Sendable (FetchedMessage) -> Void)? = nil) -> OneTimeCodeResolver {
        OneTimeCodeResolver(
            mailboxes: { mailboxes },
            fetcher: fetcher,
            extractor: FakeExtractor(),
            judge: judge,
            usage: usage,
            perMailboxBudget: budget,
            now: { OneTimeCodeResolverTests.fixedNow },
            fillReportRetry: retry,
            chosenObserver: chosenObserver
        )
    }

    // MARK: - Tests

    func testChosenReturnsCodeOfChosenMessage() async {
        let a = mailbox("a@example.com")
        let m1 = message("\(a.id):1", a, body: "CODE:111111")
        let m2 = message("\(a.id):2", a, body: "CODE:222222")
        let fetcher = FakeFetcher(results: [a.id: .messages([m1, m2])])
        let judge = FakeJudge(outcome: .chosen(messageID: m2.id, scores: [m2.id: 0.9]))

        let result = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge)
            .resolve(service: "acme.example.com")

        XCTAssertEqual(result, ResolvedCode(code: "222222", messageID: m2.id))
        let calls = await judge.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.service, "acme.example.com")
    }

    func testFetchUsesTenMinuteWindow() async {
        let a = mailbox("a@example.com")
        let fetcher = FakeFetcher(results: [a.id: .messages([])])
        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: FakeJudge(outcome: .quotaExhausted))
            .resolve(service: nil)
        let sinces = await fetcher.sinces
        XCTAssertEqual(sinces, [now.addingTimeInterval(-600)])
    }

    func testOnlyMessagesWithCodeGoToJudge() async {
        let a = mailbox("a@example.com")
        let withCode = message("\(a.id):1", a, body: "CODE:123456")
        let withoutCode = message("\(a.id):2", a, body: "Newsletter, no code")
        let fetcher = FakeFetcher(results: [a.id: .messages([withCode, withoutCode])])
        let judge = FakeJudge(outcome: .noMatch(scores: [:]))

        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge).resolve(service: "x.example")

        let calls = await judge.calls
        XCTAssertEqual(calls.map { $0.messageIDs }, [[withCode.id]])
    }

    func testNoCandidatesDoesNotCallJudge() async {
        let a = mailbox("a@example.com")
        let fetcher = FakeFetcher(results: [a.id: .messages([message("\(a.id):1", a, body: "hello")])])
        let judge = FakeJudge(outcome: .chosen(messageID: "unused", scores: [:]))

        let result = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge).resolve(service: nil)

        XCTAssertNil(result)
        let calls = await judge.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testNoMatchReturnsNil() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let fetcher = FakeFetcher(results: [a.id: .messages([m])])
        let result = await makeResolver(mailboxes: [a], fetcher: fetcher,
                                        judge: FakeJudge(outcome: .noMatch(scores: [m.id: 0.1])))
            .resolve(service: "acme.example.com")
        XCTAssertNil(result)
    }

    func testQuotaExhaustedReturnsNil() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let fetcher = FakeFetcher(results: [a.id: .messages([m])])
        let result = await makeResolver(mailboxes: [a], fetcher: fetcher,
                                        judge: FakeJudge(outcome: .quotaExhausted))
            .resolve(service: "acme.example.com")
        XCTAssertNil(result)
    }

    func testJudgeErrorReturnsNil() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let fetcher = FakeFetcher(results: [a.id: .messages([m])])
        let result = await makeResolver(mailboxes: [a], fetcher: fetcher,
                                        judge: FakeJudge(outcome: nil))
            .resolve(service: "acme.example.com")
        XCTAssertNil(result)
    }

    func testChosenIDUnknownReturnsNil() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let fetcher = FakeFetcher(results: [a.id: .messages([m])])
        let result = await makeResolver(mailboxes: [a], fetcher: fetcher,
                                        judge: FakeJudge(outcome: .chosen(messageID: "other:9", scores: [:])))
            .resolve(service: nil)
        XCTAssertNil(result)
    }

    func testMailboxSourceErrorReturnsNil() async {
        let judge = FakeJudge(outcome: .chosen(messageID: "x", scores: [:]))
        let resolver = OneTimeCodeResolver(
            mailboxes: { throw FakeError.failed },
            fetcher: FakeFetcher(results: [:]),
            extractor: FakeExtractor(),
            judge: judge,
            usage: FakeUsage(),
            now: { OneTimeCodeResolverTests.fixedNow }
        )
        let result = await resolver.resolve(service: nil)
        XCTAssertNil(result)
        let calls = await judge.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailedMailboxIsSkipped() async {
        let a = mailbox("a@example.com")
        let b = mailbox("b@example.com")
        let mb = message("\(b.id):7", b, body: "CODE:777777")
        let fetcher = FakeFetcher(results: [a.id: .failure, b.id: .messages([mb])])
        let judge = FakeJudge(outcome: .chosen(messageID: mb.id, scores: [:]))

        let result = await makeResolver(mailboxes: [a, b], fetcher: fetcher, judge: judge).resolve(service: nil)

        XCTAssertEqual(result?.code, "777777")
    }

    func testMailboxesAreFetchedInParallel() async {
        let boxes = (0..<4).map { mailbox("m\($0)@example.com") }
        var results: [UUID: FakeFetcher.Result] = [:]
        for box in boxes {
            results[box.id] = .delayed(.milliseconds(400), [message("\(box.id):1", box, body: "CODE:100000")])
        }
        let fetcher = FakeFetcher(results: results)
        let judge = FakeJudge(outcome: .noMatch(scores: [:]))
        let resolver = makeResolver(mailboxes: boxes, fetcher: fetcher, judge: judge)

        let start = ContinuousClock.now
        _ = await resolver.resolve(service: nil)
        let elapsed = ContinuousClock.now - start

        // Sequential would take >= 1.6 s.
        XCTAssertLessThan(elapsed, .milliseconds(1_200))
        let peak = await fetcher.peakConcurrency
        XCTAssertEqual(peak, 4)
        let calls = await judge.calls
        XCTAssertEqual(calls.first?.messageIDs.count, 4)
    }

    func testSlowMailboxIsSkippedAfterBudget() async {
        let fast = mailbox("fast@example.com")
        let slow = mailbox("slow@example.com")
        let mf = message("\(fast.id):1", fast, body: "CODE:111111")
        let ms = message("\(slow.id):1", slow, body: "CODE:999999")
        // The slow fetch ignores cancellation, so the budget must not wait for it.
        let fetcher = FakeFetcher(results: [
            fast.id: .messages([mf]),
            slow.id: .uncancellableDelay(.seconds(3), [ms]),
        ])
        let judge = FakeJudge(outcome: .chosen(messageID: mf.id, scores: [:]))
        let resolver = makeResolver(mailboxes: [fast, slow], fetcher: fetcher, judge: judge,
                                    budget: .milliseconds(300))

        let start = ContinuousClock.now
        let result = await resolver.resolve(service: nil)
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(result?.code, "111111")
        XCTAssertLessThan(elapsed, .milliseconds(2_000))
        let calls = await judge.calls
        XCTAssertEqual(calls.first?.messageIDs, [mf.id])
    }

    func testCandidatesAreOrderedNewestFirst() async {
        let a = mailbox("a@example.com")
        let older = message("\(a.id):1", a, body: "CODE:111111", ageSeconds: 300)
        let newer = message("\(a.id):2", a, body: "CODE:222222", ageSeconds: 30)
        let fetcher = FakeFetcher(results: [a.id: .messages([older, newer])])
        let judge = FakeJudge(outcome: .noMatch(scores: [:]))

        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge).resolve(service: nil)

        let calls = await judge.calls
        XCTAssertEqual(calls.first?.messageIDs, [newer.id, older.id])
    }

    func testReportFillCallsUsageReporter() async {
        let usage = FakeUsage()
        let resolver = makeResolver(mailboxes: [], fetcher: FakeFetcher(results: [:]),
                                    judge: FakeJudge(outcome: .quotaExhausted), usage: usage)
        await resolver.reportFill(messageID: "box:42")
        let reported = await usage.reported
        XCTAssertEqual(reported, ["box:42"])
    }

    /// A failed fill report is retried, up to 3 attempts in total, and never surfaces.
    func testReportFillRetriesThreeTimesThenGivesUp() async {
        let usage = FakeUsage(fails: true)
        let resolver = makeResolver(mailboxes: [], fetcher: FakeFetcher(results: [:]),
                                    judge: FakeJudge(outcome: .quotaExhausted), usage: usage)
        await resolver.reportFill(messageID: "box:42")
        let reported = await usage.reported
        XCTAssertEqual(reported, ["box:42", "box:42", "box:42"])
    }

    func testReportFillDoesNotRetryPermanentErrors() async {
        let usage = FakeUsage(fails: true)
        let resolver = makeResolver(mailboxes: [], fetcher: FakeFetcher(results: [:]),
                                    judge: FakeJudge(outcome: .quotaExhausted), usage: usage,
                                    retry: FillReportRetry(delays: [.milliseconds(10)], shouldRetry: { _ in false }))
        let attempts = await resolver.reportFill(messageID: "box:42")
        XCTAssertEqual(attempts, 1)
        let reported = await usage.reported
        XCTAssertEqual(reported, ["box:42"])
    }

    func testObserverSeesOnlyTheChosenMessageAndNothingWithoutAChoice() async {
        let a = mailbox("a@example.com")
        let m1 = message("\(a.id):1", a, body: "CODE:111111")
        let m2 = message("\(a.id):2", a, body: "CODE:222222")
        let seen = SeenIDs()
        let chosen = makeResolver(mailboxes: [a], fetcher: FakeFetcher(results: [a.id: .messages([m1, m2])]),
                                  judge: FakeJudge(outcome: .chosen(messageID: m1.id, scores: [:])),
                                  chosenObserver: { seen.add($0.id) })
        _ = await chosen.resolve(service: nil)
        XCTAssertEqual(seen.all, [m1.id])

        let none = makeResolver(mailboxes: [a], fetcher: FakeFetcher(results: [a.id: .messages([m1, m2])]),
                                judge: FakeJudge(outcome: .noMatch(scores: [:])),
                                chosenObserver: { seen.add($0.id) })
        _ = await none.resolve(service: nil)
        XCTAssertEqual(seen.all, [m1.id])
    }

    func testReportFillStopsRetryingAfterSuccess() async {
        let usage = FakeUsage(failures: 1)
        let resolver = makeResolver(mailboxes: [], fetcher: FakeFetcher(results: [:]),
                                    judge: FakeJudge(outcome: .quotaExhausted), usage: usage)
        await resolver.reportFill(messageID: "box:42")
        let reported = await usage.reported
        XCTAssertEqual(reported, ["box:42", "box:42"])
    }

    func testResolveDoesNotReportFill() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let usage = FakeUsage()
        let resolver = makeResolver(mailboxes: [a], fetcher: FakeFetcher(results: [a.id: .messages([m])]),
                                    judge: FakeJudge(outcome: .chosen(messageID: m.id, scores: [:])), usage: usage)
        _ = await resolver.resolve(service: nil)
        let reported = await usage.reported
        XCTAssertTrue(reported.isEmpty, "Fill is counted only after the system accepted the code")
    }
}

// MARK: - Fakes

private enum FakeError: Error { case failed }

private final class SeenIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func add(_ id: String) {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

/// Extracts the code after the literal prefix "CODE:" (test-only format).
private struct FakeExtractor: CodeExtracting {
    func extractCode(from message: FetchedMessage) -> String? {
        guard let range = message.bodyText.range(of: "CODE:") else { return nil }
        return String(message.bodyText[range.upperBound...].prefix(6))
    }
}

private actor FakeFetcher: MailFetching {
    enum Result: Sendable {
        case messages([FetchedMessage])
        case delayed(Duration, [FetchedMessage])
        case uncancellableDelay(Duration, [FetchedMessage])
        case failure
    }

    private let results: [UUID: Result]
    private(set) var sinces: [Date] = []
    private var inFlight = 0
    private(set) var peakConcurrency = 0

    init(results: [UUID: Result]) { self.results = results }

    func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage] {
        sinces.append(since)
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }
        switch results[mailbox.id] ?? .messages([]) {
        case .messages(let list):
            return list
        case .delayed(let delay, let list):
            try await Task.sleep(for: delay)
            return list
        case .uncancellableDelay(let delay, let list):
            let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { cont.resume() }
            }
            return list
        case .failure:
            throw FakeError.failed
        }
    }
}

private actor FakeJudge: CandidateJudging {
    struct Call: Sendable, Equatable {
        var service: String?
        var messageIDs: [String]
    }

    /// nil = throw.
    private let outcome: JudgeOutcome?
    private(set) var calls: [Call] = []

    init(outcome: JudgeOutcome?) { self.outcome = outcome }

    func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome {
        calls.append(Call(service: service, messageIDs: messages.map(\.id)))
        guard let outcome else { throw FakeError.failed }
        return outcome
    }
}

private actor FakeUsage: UsageReporting {
    /// Number of calls that fail before the first success (`Int.max` = always fails).
    private var remainingFailures: Int
    private(set) var reported: [String] = []

    init(fails: Bool = false) { remainingFailures = fails ? Int.max : 0 }
    init(failures: Int) { remainingFailures = failures }

    func reportFill(messageID: String) async throws -> Int {
        reported.append(messageID)
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw FakeError.failed
        }
        return 9
    }

    func currentUsage() async throws -> UsageSnapshot {
        UsageSnapshot(plan: "free", used: 1, limit: 10, resetsAt: Date(timeIntervalSince1970: 0))
    }
}
