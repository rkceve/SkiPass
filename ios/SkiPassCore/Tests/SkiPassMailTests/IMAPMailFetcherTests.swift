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

/// INBOX plus the junk folder: discovery, merge order, unique ids, the shared cap and budget.
final class IMAPMailFetcherJunkFolderTests: XCTestCase {
    private let since = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!
    private let mailbox = MailboxConfig(address: "me@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                        imapPort: 993, username: "me@gmail.com")
    private let spam = "[Gmail]/Spam"

    private func fetcher(_ session: ScriptedSession, timeout: TimeInterval = 3, maxMessages: Int = 50,
                         cache: JunkFolderCache = JunkFolderCache()) -> IMAPMailFetcher {
        IMAPMailFetcher(credentials: ClosureCredentialProvider { _ in .password("pw") },
                        timeout: timeout, maxMessages: maxMessages, junkFolders: cache, makeSession: { _ in session })
    }

    /// Messages received `seconds` after `since` (negative = before the window), keyed by UID.
    private func infos(_ received: [UInt32: TimeInterval]) -> [UInt32: MessageInfo] {
        var result: [UInt32: MessageInfo] = [:]
        for (uid, seconds) in received {
            result[uid] = ScriptedSession.info(uid: uid, internalDate: since.addingTimeInterval(seconds))
        }
        return result
    }

    private func id(_ folder: String, _ uid: UInt32) -> String {
        "\(mailbox.id.uuidString):\(folder):\(uid)"
    }

    /// The device bug: the code email was delivered to Gmail's Spam folder, INBOX had nothing new.
    func testCodeEmailInTheSpamFolderIsReturned() async throws {
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: -7_200]), spam: infos([40: 30, 39: -86_400])],
                                       listing: JunkFolderTests.gmailListing)
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(\.id), [id("junk", 40)])
        XCTAssertEqual(messages.first?.bodyText, "Junk code is 200040")
        let examined = await scripted.examined
        XCTAssertEqual(examined, ["INBOX", spam])
    }

    func testInboxIsReadFirstThenJunkAndBothAreMergedNewestFirst() async throws {
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 60, 2: 180]), spam: infos([1: 120, 500: -3_600])],
                                       listing: JunkFolderTests.gmailListing)
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(\.id), [id("inbox", 2), id("junk", 1), id("inbox", 1)])
        let examined = await scripted.examined
        let bodyFolders = await scripted.partCallFolders
        let listCalls = await scripted.listCalls
        let loggedOut = await scripted.loggedOut
        XCTAssertEqual(examined, ["INBOX", spam], "read-only EXAMINE of INBOX, then of the junk folder")
        XCTAssertEqual(bodyFolders, ["INBOX", spam], "INBOX bodies are read before junk bodies")
        XCTAssertEqual(listCalls, 1)
        XCTAssertTrue(loggedOut)
    }

    func testIdsStayUniqueWhenBothFoldersUseTheSameUIDs() async throws {
        let same: [UInt32: TimeInterval] = [1: 10, 2: 20, 3: 30, 4: 40, 5: 50]
        let scripted = ScriptedSession(folders: ["INBOX": infos(same), spam: infos(same)],
                                       listing: JunkFolderTests.gmailListing)
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.count, 10)
        XCTAssertEqual(Set(messages.map(\.id)).count, 10, "the server rejects a judge request with a repeated id")
        XCTAssertEqual(Set(messages.map(\.id)),
                       Set((1...5).map { id("inbox", UInt32($0)) } + (1...5).map { id("junk", UInt32($0)) }))
    }

    func testJunkFolderIsFoundByKnownNameWithoutJunkAttribute() async throws {
        let listing = [Mailbox.Info(name: "INBOX", attributes: [.hasNoChildren], hierarchyDelimiter: "/"),
                       Mailbox.Info(name: "Bulk Mail", attributes: [.hasNoChildren], hierarchyDelimiter: "/")]
        let scripted = ScriptedSession(folders: ["INBOX": [:], "Bulk Mail": infos([3: 5])], listing: listing)
        let messages = try await fetcher(scripted).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(\.id), [id("junk", 3)])
        let examined = await scripted.examined
        XCTAssertEqual(examined, ["INBOX", "Bulk Mail"])
    }

    func testJunkFolderIsListedOncePerMailbox() async throws {
        let cache = JunkFolderCache()
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10]), spam: infos([2: 20])],
                                       listing: JunkFolderTests.gmailListing)
        let sut = fetcher(scripted, cache: cache)
        _ = try await sut.recentMessages(for: mailbox, since: since)
        let second = try await sut.recentMessages(for: mailbox, since: since)

        XCTAssertEqual(second.map(\.id), [id("junk", 2), id("inbox", 1)])
        let listCalls = await scripted.listCalls
        let examined = await scripted.examined
        XCTAssertEqual(listCalls, 1, "the second lookup uses the remembered folder")
        XCTAssertEqual(examined, ["INBOX", spam, "INBOX", spam])
        XCTAssertEqual(cache.entry(for: mailbox), .found(spam))
    }

    func testMissingJunkFolderIsRememberedToo() async throws {
        let cache = JunkFolderCache()
        let listing = [Mailbox.Info(name: "INBOX", attributes: [.hasNoChildren], hierarchyDelimiter: "/")]
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10])], listing: listing)
        let sut = fetcher(scripted, cache: cache)
        _ = try await sut.recentMessages(for: mailbox, since: since)
        let second = try await sut.recentMessages(for: mailbox, since: since)

        XCTAssertEqual(second.map(\.id), [id("inbox", 1)])
        let listCalls = await scripted.listCalls
        let examined = await scripted.examined
        XCTAssertEqual(listCalls, 1)
        XCTAssertEqual(examined, ["INBOX", "INBOX"])
        XCTAssertEqual(cache.entry(for: mailbox), .notFound)
    }

    func testRememberedJunkFolderThatNoLongerOpensIsLookedUpAgain() async throws {
        let cache = JunkFolderCache()
        cache.store(.found("Junk"), for: mailbox)  // renamed on the server since it was found
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10]), spam: infos([2: 20])],
                                       listing: JunkFolderTests.gmailListing)
        let sut = fetcher(scripted, cache: cache)

        let first = try await sut.recentMessages(for: mailbox, since: since)
        XCTAssertEqual(first.map(\.id), [id("inbox", 1)], "INBOX messages survive the failed EXAMINE")
        XCTAssertNil(cache.entry(for: mailbox))

        let second = try await sut.recentMessages(for: mailbox, since: since)
        XCTAssertEqual(second.map(\.id), [id("junk", 2), id("inbox", 1)])
        XCTAssertEqual(cache.entry(for: mailbox), .found(spam))
        let examined = await scripted.examined
        XCTAssertEqual(examined, ["INBOX", "Junk", "INBOX", spam])
    }

    func testCapIsSharedAndInboxComesFirst() async throws {
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10, 2: 20, 3: 30]),
                                                 spam: infos([7: 5, 8: 15, 9: 25])],
                                       listing: JunkFolderTests.gmailListing)
        let messages = try await fetcher(scripted, maxMessages: 4).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(\.id), [id("inbox", 3), id("junk", 9), id("inbox", 2), id("inbox", 1)],
                       "all INBOX messages, then the newest junk message that still fits")
    }

    func testFullInboxLeavesNoRoomForTheJunkFolder() async throws {
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10, 2: 20, 3: 30]), spam: infos([9: 25])],
                                       listing: JunkFolderTests.gmailListing)
        let messages = try await fetcher(scripted, maxMessages: 3).recentMessages(for: mailbox, since: since)

        XCTAssertEqual(messages.map(\.id), [id("inbox", 3), id("inbox", 2), id("inbox", 1)])
        let listCalls = await scripted.listCalls
        let examined = await scripted.examined
        XCTAssertEqual(listCalls, 0)
        XCTAssertEqual(examined, ["INBOX"])
    }

    /// The junk folder shares the budget: when it runs out there, the INBOX messages are returned.
    func testBudgetEndingInTheJunkFolderReturnsTheInboxMessages() async throws {
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10, 2: 20]), spam: infos([3: 30])],
                                       listing: JunkFolderTests.gmailListing, stallFolder: spam)
        let start = Date()
        let messages = try await fetcher(scripted, timeout: 0.5).recentMessages(for: mailbox, since: since)

        XCTAssertLessThan(Date().timeIntervalSince(start), promptBound)
        XCTAssertEqual(messages.map(\.id), [id("inbox", 2), id("inbox", 1)])
        try await Task.sleep(nanoseconds: 100_000_000)
        let disconnected = await scripted.disconnected
        XCTAssertTrue(disconnected, "the connection is dropped at the deadline")
    }

    /// A LIST that does not answer in time costs the junk folder only, and nothing is remembered.
    func testStalledFolderListingReturnsTheInboxMessages() async throws {
        let cache = JunkFolderCache()
        let scripted = ScriptedSession(folders: ["INBOX": infos([1: 10]), spam: infos([3: 30])],
                                       listing: JunkFolderTests.gmailListing, stallListing: true)
        let start = Date()
        let messages = try await fetcher(scripted, timeout: 0.5, cache: cache).recentMessages(for: mailbox, since: since)

        XCTAssertLessThan(Date().timeIntervalSince(start), promptBound)
        XCTAssertEqual(messages.map(\.id), [id("inbox", 1)])
        XCTAssertNil(cache.entry(for: mailbox))
    }
}

/// Scripted `MailSession` with folders. Every message has a single text/plain part: "Your code is
/// 1000<uid>" in INBOX, "Junk code is 2000<uid>" elsewhere, unless `bodies` says otherwise. Body calls
/// from index `stallBodyCallsFrom` on, body calls in `stallFolder`, and LIST when `stallListing` hang for
/// `stallSeconds` and ignore cancellation, like a SwiftMail command waiting on its own timeout.
/// EXAMINE of a folder that is not in `folders` fails, like a server's NO.
actor ScriptedSession: MailSession {
    struct Key: Hashable {
        let uid: UInt32
        let section: Section
    }

    struct NoSuchFolder: Error {}

    private let folders: [String: [UInt32: MessageInfo]]
    private let listing: [Mailbox.Info]
    private let stallBodyCallsFrom: Int?
    private let stallFolder: String?
    private let stallListing: Bool
    private let bodies: [Key: String]
    private var current: String?
    private(set) var examined: [String] = []
    private(set) var listCalls = 0
    private(set) var infoCalls: [[UInt32]] = []
    private(set) var partCalls: [[UInt32]] = []
    private(set) var partCallFolders: [String] = []
    private(set) var loggedOut = false
    private(set) var disconnected = false

    /// INBOX only; the LIST reply shows no junk folder.
    init(infos: [UInt32: MessageInfo], stallBodyCallsFrom: Int?, bodies: [Key: String] = [:]) {
        self.init(folders: ["INBOX": infos],
                  listing: [Mailbox.Info(name: "INBOX", attributes: [.hasNoChildren], hierarchyDelimiter: "/")],
                  stallBodyCallsFrom: stallBodyCallsFrom, bodies: bodies)
    }

    init(folders: [String: [UInt32: MessageInfo]], listing: [Mailbox.Info], stallBodyCallsFrom: Int? = nil,
         stallFolder: String? = nil, stallListing: Bool = false, bodies: [Key: String] = [:]) {
        self.folders = folders
        self.listing = listing
        self.stallBodyCallsFrom = stallBodyCallsFrom
        self.stallFolder = stallFolder
        self.stallListing = stallListing
        self.bodies = bodies
    }

    static func info(uid: UInt32, internalDate: Date, parts: [MessagePart]? = nil) -> MessageInfo {
        MessageInfo(sequenceNumber: SequenceNumber(uid), uid: UID(uid), subject: "Your code",
                    from: "Acme <no-reply@acme.example>", to: ["me@example.com"], date: internalDate,
                    internalDate: internalDate,
                    parts: parts ?? [MessagePart(section: Section([1]), contentType: "text/plain; charset=utf-8",
                                                 encoding: "quoted-printable")])
    }

    private var currentInfos: [UInt32: MessageInfo] {
        current.flatMap { folders[$0] } ?? [:]
    }

    func open(username: String, credential: MailCredential) async throws {}

    func examine(_ folder: String) async throws {
        examined.append(folder)
        guard folders[folder] != nil else {
            current = nil
            throw NoSuchFolder()
        }
        current = folder
    }

    func listFolders() async throws -> FolderList {
        listCalls += 1
        if stallListing { await uncancellableSleep(stallSeconds) }
        return FolderList(mailboxes: listing, namespaces: nil)
    }

    func searchUIDs(since day: Date) async throws -> [UID] {
        currentInfos.keys.sorted().map { UID($0) }
    }

    func fetchInfos(_ uids: [UID]) async throws -> [MessageInfo] {
        infoCalls.append(uids.map(\.value))
        let infos = currentInfos
        return uids.compactMap { infos[$0.value] }
    }

    func fetchParts(_ requests: [(uid: UID, section: Section)]) async throws -> [UID: [(section: Section, data: Data)]] {
        let call = partCalls.count
        let folder = current ?? ""
        partCalls.append(requests.map(\.uid.value))
        partCallFolders.append(folder)
        if let stall = stallBodyCallsFrom, call >= stall {
            await uncancellableSleep(stallSeconds)
        }
        if folder == stallFolder {
            await uncancellableSleep(stallSeconds)
        }
        var result: [UID: [(section: Section, data: Data)]] = [:]
        for request in requests {
            let fallback = folder == "INBOX" ? "Your code is \(100_000 + request.uid.value)"
                                             : "Junk code is \(200_000 + request.uid.value)"
            let text = bodies[Key(uid: request.uid.value, section: request.section)] ?? fallback
            result[request.uid, default: []].append((section: request.section, data: Data(text.utf8)))
        }
        return result
    }

    func logout() async { loggedOut = true }

    func disconnect() async { disconnected = true }
}
