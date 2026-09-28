import Foundation
@testable import SkiPassMail
import SkiPassModels
import SwiftMail
import XCTest

/// Fetch order and budget handling of `IMAPMailFetcher` against a scripted IMAP session.
/// No network is touched.
final class IMAPMailFetcherOrderTests: XCTestCase {
    private let since = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!
    private let mailbox = MailboxConfig(address: "me@example.com", kind: .imap, imapHost: "imap.example.com",
                                        imapPort: 993, username: "me@example.com")

    private func uidOf(_ message: FetchedMessage) -> UInt32 {
        UInt32(message.id.split(separator: ":").last!)!
    }

    private func fetcher(_ session: ScriptedSession, timeout: TimeInterval = 3, maxMessages: Int = 50) -> IMAPMailFetcher {
        IMAPMailFetcher(credentials: ClosureCredentialProvider { _ in .password("pw") },
                        timeout: timeout, maxMessages: maxMessages, makeSession: { _ in session })
    }

    /// `recent` UIDs were received after `since` (one minute apart, higher UID = newer); `old` before it.
    private func session(recent: [UInt32], old: [UInt32] = [], stallBodyCallsFrom: Int? = nil) -> ScriptedSession {
        var infos: [UInt32: MessageInfo] = [:]
        for uid in recent {
            infos[uid] = ScriptedSession.info(uid: uid, internalDate: since.addingTimeInterval(TimeInterval(uid) * 1))
        }
        for uid in old {
            infos[uid] = ScriptedSession.info(uid: uid, internalDate: since.addingTimeInterval(-3_600 - TimeInterval(uid)))
        }
        return ScriptedSession(infos: infos, stallBodyCallsFrom: stallBodyCallsFrom)
    }

    func testBodiesAreReadNewestFirstInPipelinedBatches() async throws {
        let scripted = session(recent: Array(1...12))
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(uidOf), Array((1...12).reversed()))
        XCTAssertEqual(messages.first?.bodyText, "Your code is 100012")
        let bodyCalls = await scripted.partCalls
        XCTAssertEqual(bodyCalls.first, [12, 11, 10, 9, 8], "newest messages first, several per burst")
        XCTAssertEqual(bodyCalls.count, 3)
        let loggedOut = await scripted.loggedOut
        XCTAssertTrue(loggedOut)
    }

    func testRecencyCutIsAppliedBeforeTheCap() async throws {
        // 30 recent messages (more than one envelope batch), older mail below them, and one old message
        // that was moved into INBOX later and therefore has the highest UID.
        let scripted = session(recent: Array(11...40), old: Array(1...10) + [41])
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(uidOf), Array((11...40).reversed()))
        let infoCalls = await scripted.infoCalls
        XCTAssertEqual(infoCalls.first?.first, 41, "envelopes are walked from the newest UID")
        XCTAssertEqual(infoCalls.count, 2, "stops after the batch that reaches older mail")
    }

    func testCapKeepsTheNewestMessages() async throws {
        let scripted = session(recent: Array(1...10))
        let messages = try await fetcher(scripted, maxMessages: 3).recentMessages(for: mailbox, since: since)
        XCTAssertEqual(messages.map(uidOf), [10, 9, 8])
    }

    func testMessagesReadBeforeTheBudgetEndsAreReturned() async throws {
        let scripted = session(recent: Array(1...10), stallBodyCallsFrom: 1)
        let start = Date()
        let messages = try await fetcher(scripted, timeout: 0.5).recentMessages(for: mailbox, since: since)

        XCTAssertLessThan(Date().timeIntervalSince(start), promptBound)
        XCTAssertEqual(messages.map(uidOf), [10, 9, 8, 7, 6], "the first burst (newest five) is kept")
        try await Task.sleep(nanoseconds: 100_000_000)
        let disconnected = await scripted.disconnected
        XCTAssertTrue(disconnected, "the connection is dropped at the deadline")
    }

    func testHTMLIsUsedWhenThePlainPartIsEmpty() async throws {
        let plain = MessagePart(section: Section([1]), contentType: "text/plain; charset=utf-8", encoding: "quoted-printable")
        let html = MessagePart(section: Section([2]), contentType: "text/html; charset=utf-8", encoding: "quoted-printable")
        let info = ScriptedSession.info(uid: 5, internalDate: since.addingTimeInterval(30), parts: [plain, html])
        let scripted = ScriptedSession(infos: [5: info], stallBodyCallsFrom: nil,
                                       bodies: [ScriptedSession.Key(uid: 5, section: Section([1])): " \n",
                                                ScriptedSession.Key(uid: 5, section: Section([2])): "<p>Code <b>482913</b></p>"])
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].bodyText.contains("482913"), messages[0].bodyText)
        let bodyCalls = await scripted.partCalls
        XCTAssertEqual(bodyCalls, [[5], [5]])
    }

    func testCallerCancellationDropsTheConnection() async throws {
        let scripted = session(recent: Array(1...10), stallBodyCallsFrom: 0)
        let sut = self.fetcher(scripted, timeout: 10)
        let mailbox = self.mailbox
        let since = self.since
        let task = Task { try await sut.recentMessages(for: mailbox, since: since) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.result
        try await Task.sleep(nanoseconds: 200_000_000)
        let disconnected = await scripted.disconnected
        XCTAssertTrue(disconnected)
    }
}

/// Scripted `MailSession`: every message has a single text/plain part "Your code is 1000<uid>"
/// unless `bodies` says otherwise. Body calls from index `stallBodyCallsFrom` on hang for 3 s and
/// ignore cancellation, like a SwiftMail command waiting on its own timeout.
actor ScriptedSession: MailSession {
    struct Key: Hashable {
        let uid: UInt32
        let section: Section
    }

    private let infos: [UInt32: MessageInfo]
    private let stallBodyCallsFrom: Int?
    private let bodies: [Key: String]
    private(set) var infoCalls: [[UInt32]] = []
    private(set) var partCalls: [[UInt32]] = []
    private(set) var loggedOut = false
    private(set) var disconnected = false

    init(infos: [UInt32: MessageInfo], stallBodyCallsFrom: Int?, bodies: [Key: String] = [:]) {
        self.infos = infos
        self.stallBodyCallsFrom = stallBodyCallsFrom
        self.bodies = bodies
    }

    static func info(uid: UInt32, internalDate: Date, parts: [MessagePart]? = nil) -> MessageInfo {
        MessageInfo(sequenceNumber: SequenceNumber(uid), uid: UID(uid), subject: "Your code",
                    from: "Acme <no-reply@acme.example>", to: ["me@example.com"], date: internalDate,
                    internalDate: internalDate,
                    parts: parts ?? [MessagePart(section: Section([1]), contentType: "text/plain; charset=utf-8",
                                                 encoding: "quoted-printable")])
    }

    func open(username: String, credential: MailCredential) async throws {}

    func searchUIDs(since day: Date) async throws -> [UID] {
        infos.keys.sorted().map { UID($0) }
    }

    func fetchInfos(_ uids: [UID]) async throws -> [MessageInfo] {
        infoCalls.append(uids.map(\.value))
        return uids.compactMap { infos[$0.value] }
    }

    func fetchParts(_ requests: [(uid: UID, section: Section)]) async throws -> [UID: [(section: Section, data: Data)]] {
        let call = partCalls.count
        partCalls.append(requests.map(\.uid.value))
        if let stall = stallBodyCallsFrom, call >= stall {
            await uncancellableSleep(stallSeconds)
        }
        var result: [UID: [(section: Section, data: Data)]] = [:]
        for request in requests {
            let text = bodies[Key(uid: request.uid.value, section: request.section)] ?? "Your code is \(100_000 + request.uid.value)"
            result[request.uid, default: []].append((section: request.section, data: Data(text.utf8)))
        }
        return result
    }

    func logout() async { loggedOut = true }

    func disconnect() async { disconnected = true }
}
