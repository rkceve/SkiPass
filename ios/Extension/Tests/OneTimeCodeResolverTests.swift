import XCTest
import SkiPassModels

// Unit tests for OneTimeCodeResolver (docs/ARCHITECTURE.md §3). The resolver depends only on
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
                              fetchRetry: FetchRetry = OneTimeCodeResolverTests.quickRetry,
                              retry: FillReportRetry = FillReportRetry(delays: [.milliseconds(10)]),
                              chosenObserver: (@Sendable (FetchedMessage) -> Void)? = nil,
                              sink: TraceSink? = nil) -> OneTimeCodeResolver {
        OneTimeCodeResolver(
            mailboxes: { mailboxes },
            fetcher: fetcher,
            extractor: FakeExtractor(),
            judge: judge,
            usage: usage,
            perMailboxBudget: budget,
            retry: fetchRetry,
            now: { OneTimeCodeResolverTests.fixedNow },
            fillReportRetry: retry,
            chosenObserver: chosenObserver,
            diagnostics: sink.map { sink in ResolverDiagnostics(finish: { sink.add($0) }) }
        )
    }

    /// The retry of the production schedule, with a short delay so tests stay fast.
    static let quickRetry = FetchRetry(delay: .milliseconds(20), mailDeadline: .seconds(10), minimumBudget: .milliseconds(100))

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

    /// INBOX and the junk folder number their messages independently. The folder in the id
    /// ("<mailboxID>:<folder>:<uid>", docs/API.md) keeps a junk-folder code distinct from an INBOX
    /// message with the same UID, from judging through the fill report.
    func testSameUIDInInboxAndJunkStayDistinctThroughJudgeAndFillReport() async throws {
        let a = mailbox("a@example.com")
        let inbox = message("\(a.id.uuidString):inbox:7", a, body: "CODE:111111", ageSeconds: 30)
        let junk = message("\(a.id.uuidString):junk:7", a, body: "CODE:222222", ageSeconds: 60)
        let fetcher = FakeFetcher(results: [a.id: .messages([inbox, junk])])
        let judge = FakeJudge(outcome: .chosen(messageID: junk.id, scores: [:]))
        let usage = FakeUsage()
        let resolver = makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge, usage: usage)

        let result = await resolver.resolve(service: "acme.example.com")
        let resolved = try XCTUnwrap(result)
        XCTAssertEqual(resolved, ResolvedCode(code: "222222", messageID: junk.id))
        let calls = await judge.calls
        XCTAssertEqual(calls.first?.messageIDs, [inbox.id, junk.id])

        await resolver.reportFill(messageID: resolved.messageID)
        let reported = await usage.reported
        XCTAssertEqual(reported, [junk.id])
    }

    func testFetchUsesTenMinuteWindow() async {
        let a = mailbox("a@example.com")
        let fetcher = FakeFetcher(results: [a.id: .messages([])])
        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: FakeJudge(outcome: .quotaExhausted))
            .resolve(service: nil)
        let sinces = await fetcher.sinces
        // No code in the first read, so the mailbox is read a second time, with the same window.
        XCTAssertEqual(sinces, [now.addingTimeInterval(-600), now.addingTimeInterval(-600)])
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

    // MARK: - Budget and retry

    func testDefaultBudgetAndRetryStayWithinTheRequestBound() {
        XCTAssertEqual(OneTimeCodeResolver.defaultPerMailboxBudget, .seconds(8))
        let retry = FetchRetry()
        XCTAssertEqual(retry.delay, .milliseconds(2_500))
        // A fast first read leaves the full per-mailbox budget for the second.
        XCTAssertEqual(retry.secondBudget(elapsed: .seconds(1), perMailboxBudget: .seconds(8)), .seconds(8))
        // A first read that used its whole budget leaves what is left of the 13 s mail deadline.
        XCTAssertEqual(retry.secondBudget(elapsed: .seconds(8), perMailboxBudget: .seconds(8)), .milliseconds(2_500))
        // Too little left: no second read.
        XCTAssertNil(retry.secondBudget(elapsed: .seconds(9), perMailboxBudget: .seconds(8)))
        // Worst case of all mail reading: first read + delay + second read <= mail deadline (13 s);
        // the judge (7 s server timeout) comes on top, about 20 s in all.
        for elapsedSeconds in 0...8 {
            let elapsed = Duration.seconds(elapsedSeconds)
            if let second = retry.secondBudget(elapsed: elapsed, perMailboxBudget: .seconds(8)) {
                XCTAssertLessThanOrEqual(elapsed + retry.delay + second, .seconds(13))
            }
        }
    }

    /// The code email arrives after the first read: the second read, after the delay, finds it.
    func testSecondReadAfterTheDelayFindsALateCode() async {
        let a = mailbox("a@example.com")
        let late = message("\(a.id):inbox:9", a, body: "CODE:424242", ageSeconds: 5)
        let fetcher = FakeFetcher(results: [a.id: .sequence([[], [late]])])
        let judge = FakeJudge(outcome: .chosen(messageID: late.id, scores: [:]))
        let sink = TraceSink()
        let retry = FetchRetry(delay: .milliseconds(300), mailDeadline: .seconds(10), minimumBudget: .milliseconds(100))

        let start = ContinuousClock.now
        let result = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge, fetchRetry: retry, sink: sink)
            .resolve(service: "acme.example.com")
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(result?.code, "424242")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300), "the second read waits for the delay")
        let calls = await fetcher.sinces
        XCTAssertEqual(calls.count, 2)
        let trace = sink.all.first
        XCTAssertEqual(trace?.rounds, 2)
        XCTAssertEqual(trace?.mailboxes.map(\.round), [1, 2])
        XCTAssertEqual(trace?.outcome, "filled")
    }

    /// Only one extra read: with no code in either read the request ends.
    func testAtMostOneSecondRead() async {
        let a = mailbox("a@example.com")
        let fetcher = FakeFetcher(results: [a.id: .messages([])])
        let judge = FakeJudge(outcome: .quotaExhausted)
        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: judge).resolve(service: nil)
        let calls = await fetcher.sinces
        XCTAssertEqual(calls.count, 2)
        let judged = await judge.calls
        XCTAssertTrue(judged.isEmpty)
    }

    /// When the first read used up the mail deadline, there is no second read.
    func testNoSecondReadWhenNoTimeIsLeft() async {
        let a = mailbox("a@example.com")
        let fetcher = FakeFetcher(results: [a.id: .messages([])])
        let noTime = FetchRetry(delay: .milliseconds(20), mailDeadline: .milliseconds(50), minimumBudget: .milliseconds(100))
        let sink = TraceSink()
        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: FakeJudge(outcome: .quotaExhausted),
                               fetchRetry: noTime, sink: sink).resolve(service: nil)
        let calls = await fetcher.sinces
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(sink.all.first?.reason, "no code email found")
    }

    /// A found code never triggers the second read.
    func testNoSecondReadWhenACodeWasFound() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let fetcher = FakeFetcher(results: [a.id: .messages([m])])
        _ = await makeResolver(mailboxes: [a], fetcher: fetcher, judge: FakeJudge(outcome: .noMatch(scores: [:])))
            .resolve(service: nil)
        let calls = await fetcher.sinces
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Trace

    func testTraceOfAFilledRequest() async throws {
        let a = mailbox("robert@gmail.com")
        let m = message("\(a.id.uuidString):junk:4", a, body: "CODE:654321 secret body")
        let sink = TraceSink()
        let resolver = makeResolver(mailboxes: [a], fetcher: FakeFetcher(results: [a.id: .messages([m])]),
                                    judge: FakeJudge(outcome: .chosen(messageID: m.id, scores: [:])), sink: sink)

        _ = await resolver.resolve(service: "skipass-demo.vercel.app", entryPoint: "noUI")

        XCTAssertEqual(sink.all.count, 1)
        let trace = try XCTUnwrap(sink.all.first)
        XCTAssertEqual(trace.entryPoint, "noUI")
        XCTAssertEqual(trace.service, "skipass-demo.vercel.app")
        XCTAssertEqual(trace.mailboxCount, 1)
        XCTAssertEqual(trace.mailboxes.first?.mailbox, "r***@gmail.com")
        XCTAssertEqual(trace.mailboxes.first?.messages, 1)
        XCTAssertEqual(trace.candidateCount, 1)
        XCTAssertEqual(trace.judge?.outcome, "chosen")
        XCTAssertEqual(trace.judge?.chosenID, m.id)
        XCTAssertEqual(trace.outcome, "filled")
        XCTAssertNil(trace.reason)
        XCTAssertNotNil(trace.totalMs)

        let json = String(decoding: try JSONEncoder().encode(trace), as: UTF8.self)
        XCTAssertFalse(json.contains("654321"), "no code in the trace")
        XCTAssertFalse(json.contains("secret body"), "no email text in the trace")
        XCTAssertFalse(json.contains("robert@gmail.com"), "addresses are masked")
    }

    func testTraceNamesWhyNothingWasFilled() async {
        let a = mailbox("a@example.com")
        let m = message("\(a.id):1", a, body: "CODE:123456")
        let cases: [(OneTimeCodeResolver.MailboxSource, FakeFetcher, FakeJudge, String)] = [
            ({ [] }, FakeFetcher(results: [:]), FakeJudge(outcome: nil), "no mailboxes visible to the extension"),
            ({ throw FakeError.failed }, FakeFetcher(results: [:]), FakeJudge(outcome: nil), "mailbox list unreadable"),
            ({ [a] }, FakeFetcher(results: [a.id: .failure]), FakeJudge(outcome: nil), "no code email found"),
            ({ [a] }, FakeFetcher(results: [a.id: .messages([m])]), FakeJudge(outcome: nil), "judge failed"),
            ({ [a] }, FakeFetcher(results: [a.id: .messages([m])]), FakeJudge(outcome: .noMatch(scores: [:])), "judge found no match"),
            ({ [a] }, FakeFetcher(results: [a.id: .messages([m])]), FakeJudge(outcome: .quotaExhausted), "monthly fills used up"),
        ]
        for (source, fetcher, judge, reason) in cases {
            let sink = TraceSink()
            let resolver = OneTimeCodeResolver(
                mailboxes: source, fetcher: fetcher, extractor: FakeExtractor(), judge: judge, usage: FakeUsage(),
                retry: Self.quickRetry, now: { OneTimeCodeResolverTests.fixedNow },
                diagnostics: ResolverDiagnostics(finish: { sink.add($0) }))
            let result = await resolver.resolve(service: "acme.example.com")
            XCTAssertNil(result)
            XCTAssertEqual(sink.all.first?.outcome, "cancelled", reason)
            XCTAssertEqual(sink.all.first?.reason, reason)
        }
    }

    func testTraceRecordsAMailboxThatExceededItsBudget() async {
        let slow = mailbox("slow@example.com")
        let fetcher = FakeFetcher(results: [slow.id: .uncancellableDelay(.seconds(2), [])])
        let sink = TraceSink()
        _ = await makeResolver(mailboxes: [slow], fetcher: fetcher, judge: FakeJudge(outcome: nil),
                               budget: .milliseconds(200), fetchRetry: .never, sink: sink).resolve(service: nil)
        let mailboxTrace = sink.all.first?.mailboxes.first
        XCTAssertEqual(mailboxTrace?.mailbox, "s***@example.com")
        XCTAssertEqual(mailboxTrace?.error, "budget of 200 ms exceeded")
    }

    func testDiagnosticsPrepareAndLogRun() async {
        let a = mailbox("a@example.com")
        let lines = TraceSink()
        let storage = StorageSnapshot(bundleID: "x.autofill", appGroup: "group.x", keychainGroup: "group.x",
                                      recordedAt: now)
        let resolver = OneTimeCodeResolver(
            mailboxes: { [a] }, fetcher: FakeFetcher(results: [a.id: .messages([])]), extractor: FakeExtractor(),
            judge: FakeJudge(outcome: nil), usage: FakeUsage(), retry: .never,
            now: { OneTimeCodeResolverTests.fixedNow },
            diagnostics: ResolverDiagnostics(
                log: { lines.addLine($0) },
                prepare: { trace in
                    trace.storage = storage
                    trace.groupsMatchApp = false
                },
                finish: { lines.add($0) }))
        _ = await resolver.resolve(service: nil, entryPoint: "textToInsert")

        XCTAssertEqual(lines.all.first?.storage, storage)
        XCTAssertEqual(lines.all.first?.groupsMatchApp, false)
        XCTAssertTrue(lines.lines.contains { $0.contains("request textToInsert") })
        XCTAssertTrue(lines.lines.contains { $0.contains("DIFFERENT from app") })
        XCTAssertTrue(lines.lines.contains { $0.contains("outcome cancelled") })
        XCTAssertFalse(lines.lines.contains { $0.contains("a@example.com") }, "log lines mask addresses")
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

/// Collects finished traces and log lines.
final class TraceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [AutoFillTrace] = []
    private var logLines: [String] = []

    func add(_ trace: AutoFillTrace) {
        lock.lock()
        traces.append(trace)
        lock.unlock()
    }

    func addLine(_ line: String) {
        lock.lock()
        logLines.append(line)
        lock.unlock()
    }

    var all: [AutoFillTrace] {
        lock.lock()
        defer { lock.unlock() }
        return traces
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return logLines
    }
}

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
        /// The n-th call gets the n-th list (the last one repeats).
        case sequence([[FetchedMessage]])
        case delayed(Duration, [FetchedMessage])
        case uncancellableDelay(Duration, [FetchedMessage])
        case failure
    }

    private let results: [UUID: Result]
    private var callsPerMailbox: [UUID: Int] = [:]
    private(set) var sinces: [Date] = []
    private var inFlight = 0
    private(set) var peakConcurrency = 0

    init(results: [UUID: Result]) { self.results = results }

    func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage] {
        sinces.append(since)
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }
        let call = callsPerMailbox[mailbox.id, default: 0]
        callsPerMailbox[mailbox.id] = call + 1
        switch results[mailbox.id] ?? .messages([]) {
        case .messages(let list):
            return list
        case .sequence(let lists):
            return lists.isEmpty ? [] : lists[min(call, lists.count - 1)]
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
