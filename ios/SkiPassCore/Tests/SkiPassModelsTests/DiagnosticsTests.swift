import Foundation
import SkiPassModels
import XCTest

/// Encoding, masking and retention of the on-device AutoFill diagnostics.
final class DiagnosticsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "diagnostics-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Masking and error summaries

    func testAddressesAreMasked() {
        XCTAssertEqual(Diagnostics.maskAddress("ryosuke@gmail.com"), "r***@gmail.com")
        XCTAssertEqual(Diagnostics.maskAddress(" a@b.example "), "a***@b.example")
        XCTAssertEqual(Diagnostics.maskAddress("@example.com"), "***@example.com")
        XCTAssertEqual(Diagnostics.maskAddress("no-at-sign"), "n***")
        XCTAssertEqual(Diagnostics.maskAddress(""), "")
    }

    func testErrorSummariesKeepTypeAndCaseButNoTokens() {
        XCTAssertEqual(Diagnostics.errorSummary(URLError(.timedOut)), "URLError -1001")
        XCTAssertEqual(Diagnostics.errorSummary(CancellationError()), "cancelled")
        XCTAssertEqual(Diagnostics.errorSummary(NSError(domain: "org.openid.appauth.oauth_token", code: -10,
                                                        userInfo: ["body": "refresh_token=abc"])),
                       "org.openid.appauth.oauth_token -10")
        XCTAssertTrue(Diagnostics.errorSummary(SampleError.httpStatus(404)).hasSuffix("httpStatus(404)"))

        let token = "ya29.a0AfB_byC1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
        let summary = Diagnostics.errorSummary(SampleError.rejected("token \(token)"))
        XCTAssertFalse(summary.contains("a0AfB_byC1234567890abcdefghijklmnopqrstuvwxyz"), summary)
        XCTAssertTrue(summary.contains("<redacted>"), summary)
        XCTAssertLessThanOrEqual(summary.count, 170)
    }

    func testRedactKeepsShortWordsAndDottedNames() {
        XCTAssertEqual(Diagnostics.redact("ServerClientError.httpStatus(503)"), "ServerClientError.httpStatus(503)")
        XCTAssertEqual(Diagnostics.redact("key ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 end"), "key <redacted> end")
    }

    func testMilliseconds() {
        XCTAssertEqual(Diagnostics.milliseconds(.milliseconds(2_500)), 2_500)
        XCTAssertEqual(Diagnostics.milliseconds(.seconds(8)), 8_000)
    }

    // MARK: Trace encoding

    private func sampleTrace(outcome: String = "cancelled", reason: String? = "no code email found") -> AutoFillTrace {
        var trace = AutoFillTrace(startedAt: date, entryPoint: "noUI", service: "skipass-demo.vercel.app")
        trace.storage = StorageSnapshot(bundleID: "io.github.rkceve.skipass.X.autofill",
                                        appGroup: "group.io.github.rkceve.skipass.X",
                                        keychainGroup: "group.io.github.rkceve.skipass.X", recordedAt: date)
        trace.groupsMatchApp = true
        trace.mailboxCount = 1
        var mailbox = MailboxTrace(mailbox: Diagnostics.maskAddress("ryosuke@gmail.com"), kind: "google", round: 1)
        mailbox.credential = StageResult(ok: true, ms: 640)
        mailbox.inbox = FolderTrace(name: "INBOX", found: true, connect: StageResult(ok: true, ms: 900),
                                    stage: "done", messages: 3, ms: 2_100)
        mailbox.junk = FolderTrace(name: "[Gmail]/Spam", found: true, connect: StageResult(ok: true, ms: 950),
                                   stage: "bodies", messages: 0, ms: 7_600, error: "cancelled")
        mailbox.messages = 3
        mailbox.ms = 7_600
        trace.mailboxes = [mailbox]
        trace.rounds = 2
        trace.candidateCount = 0
        trace.outcome = outcome
        trace.reason = reason
        trace.totalMs = 12_345
        return trace
    }

    func testTraceRoundTripsThroughJSON() throws {
        let trace = sampleTrace()
        let store = DiagnosticsStore(defaults: freshDefaults())
        store.append(trace)
        XCTAssertEqual(store.traces(), [trace])
    }

    func testStoredJSONUsesTheKeyAndHoldsNoAddressOrContent() throws {
        let defaults = freshDefaults()
        DiagnosticsStore(defaults: defaults).append(sampleTrace())
        let data = try XCTUnwrap(defaults.data(forKey: "diagnostics.autofill.v1"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("r***@gmail.com"))
        XCTAssertFalse(json.contains("ryosuke@gmail.com"))
        XCTAssertTrue(json.contains("\"entryPoint\":\"noUI\""))
    }

    func testStoreKeepsTheNewestFiveTraces() {
        let store = DiagnosticsStore(defaults: freshDefaults())
        var ids: [UUID] = []
        for index in 0..<7 {
            var trace = sampleTrace()
            trace.startedAt = date.addingTimeInterval(TimeInterval(index))
            ids.append(trace.id)
            store.append(trace)
        }
        let kept = store.traces()
        XCTAssertEqual(kept.count, Diagnostics.maxTraces)
        XCTAssertEqual(kept.map(\.id), Array(ids.suffix(5).reversed()), "newest first")
    }

    func testUnreadableTracesReadAsNone() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: Diagnostics.tracesKey)
        let store = DiagnosticsStore(defaults: defaults)
        XCTAssertEqual(store.traces(), [])
        store.append(sampleTrace())
        XCTAssertEqual(store.traces().count, 1)
    }

    func testAppStorageAndRegistrationsAreKeptPerProcess() {
        let store = DiagnosticsStore(defaults: freshDefaults())
        XCTAssertNil(store.appStorage())
        XCTAssertNil(store.registration(process: "app"))

        let app = StorageSnapshot(bundleID: "a", appGroup: "group.a", keychainGroup: "group.a", recordedAt: date)
        store.setAppStorage(app)
        store.setRegistration(RegistrationRecord(process: "app", at: date, outcome: "registered", count: 3,
                                                 storeEnabled: true))
        store.setRegistration(RegistrationRecord(process: "extension", at: date, outcome: "skipped",
                                                 detail: "no App Group in this process"))

        XCTAssertEqual(store.appStorage(), app)
        XCTAssertEqual(store.registration(process: "app")?.count, 3)
        XCTAssertEqual(store.registration(process: "extension")?.outcome, "skipped")
        XCTAssertTrue(app.sharesGroups(with: StorageSnapshot(bundleID: "a.autofill", appGroup: "group.a",
                                                             keychainGroup: "group.a", recordedAt: date)))
        XCTAssertFalse(app.sharesGroups(with: StorageSnapshot(bundleID: "a.autofill", appGroup: nil,
                                                              keychainGroup: "group.a", recordedAt: date)))
    }

    // MARK: Readable lines

    func testSummaryLinesNameEveryStage() {
        let lines = sampleTrace().summaryLines
        let text = lines.joined(separator: "\n")
        XCTAssertEqual(lines.first, "Result: cancelled (no code email found) after 12345 ms")
        XCTAssertTrue(text.contains("Entry: noUI, service skipass-demo.vercel.app"), text)
        XCTAssertTrue(text.contains("(same as app)"), text)
        XCTAssertTrue(text.contains("Mailbox r***@gmail.com (google), round 1: 3 msgs in 7600 ms"), text)
        XCTAssertTrue(text.contains("credential ok 640 ms"), text)
        XCTAssertTrue(text.contains("INBOX: \"INBOX\", connect ok 900 ms, 3 msgs, 2100 ms"), text)
        XCTAssertTrue(text.contains("junk: \"[Gmail]/Spam\""), text)
        XCTAssertTrue(text.contains("error cancelled at bodies"), text)
        XCTAssertTrue(text.contains("Code candidates: 0 after 2 round(s)"), text)
    }

    func testSummaryLinesOfMissingJunkFolderAndUnreadableMailboxes() {
        var trace = AutoFillTrace(startedAt: date, entryPoint: "credentialList", service: nil)
        trace.mailboxError = "StorageError.appGroupUnavailable"
        XCTAssertTrue(trace.summaryLines.contains("Mailboxes: unreadable (StorageError.appGroupUnavailable)"))
        XCTAssertEqual(trace.summaryLines.first, "Result: unfinished")
        XCTAssertEqual(FolderTrace(found: false, stage: "done", ms: 120).summary, "not found, 0 msgs, 120 ms")
    }

    func testRegistrationSummary() {
        XCTAssertEqual(RegistrationRecord(process: "app", at: date, outcome: "registered", count: 142,
                                          storeEnabled: true).summary, "registered 142 identities")
        XCTAssertEqual(RegistrationRecord(process: "app", at: date, outcome: "storeDisabled", storeEnabled: false).summary,
                       "storeDisabled (AutoFill off)")
        XCTAssertEqual(RegistrationRecord(process: "app", at: date, outcome: "skipped",
                                          detail: "mailbox list unreadable").summary, "skipped: mailbox list unreadable")
    }

    // MARK: Recorders

    func testRecordersCollectUpdatesAndPrefixLogLines() {
        let lines = LineSink()
        let recorder = AutoFillTraceRecorder(trace: AutoFillTrace(startedAt: date, entryPoint: "noUI", service: nil),
                                             log: { lines.add($0) })
        recorder.update { $0.mailboxCount = 2 }
        recorder.log("mailboxes 2")
        XCTAssertEqual(recorder.snapshot.mailboxCount, 2)
        XCTAssertEqual(lines.all.first?.hasSuffix("] mailboxes 2"), true)

        let mailbox = MailboxTraceRecorder(trace: MailboxTrace(mailbox: "r***@gmail.com", kind: "google", round: 2),
                                           log: { lines.add($0) })
        mailbox.log("INBOX done")
        XCTAssertEqual(lines.all.last, "r***@gmail.com r2 INBOX done")
    }
}

private enum SampleError: Error {
    case httpStatus(Int)
    case rejected(String)
}

private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
