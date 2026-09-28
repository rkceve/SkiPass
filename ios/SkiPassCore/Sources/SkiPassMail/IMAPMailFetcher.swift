import Foundation
import SkiPassModels
import SwiftMail

/// Reads recent INBOX and junk-folder messages over IMAP (SwiftMail 1.12.0) without changing mailbox state.
///
/// Read-only guarantees:
/// - Both folders are opened with EXAMINE (`IMAPServer.examineMailbox`), so the server rejects STORE and
///   does not set `\Seen` (RFC 3501 §6.3.2). `MailSession` has no command that selects read-write,
///   stores flags, copies, moves or expunges.
/// - Every SwiftMail body/header fetch uses `BODY.PEEK` (FetchCommands.swift L75, L78, L155), including
///   the pipelined part fetch, which sends the same `FetchMessagePartCommand`
///   (IMAPConnection+PipelinedFetch.swift L243).
///
/// Folders:
/// - INBOX first, then the junk folder (RFC 6154 `\Junk`, else a known name; see `JunkFolder`), on the
///   same connection and within the same time budget and recency window. The junk folder is found with
///   one IMAP LIST per mailbox and process (`JunkFolderCache`).
/// - Message ids carry the folder (`"<mailboxID>:<folder>:<uid>"`, `FetchLogic.messageID`), because
///   UIDs are only unique within a folder.
///
/// Order and budget:
/// - Envelopes are fetched newest UID first, in batches, and the exact recency cut (INTERNALDATE) is
///   applied before anything is capped; fetching stops once a batch reaches messages older than `since`.
/// - Bodies are fetched newest first, several messages per pipelined burst
///   (`IMAPServer.fetchPartsPipelined`, IMAPServer+Fetch.swift L94), and every finished message is kept.
/// - The result is both folders merged, newest (server receipt time) first.
/// - When the time budget ends, the messages read so far (from INBOX, then from the junk folder) are
///   returned instead of nothing, and the connection is dropped. The same cleanup runs when the caller
///   cancels first (Deadline.swift).
public struct IMAPMailFetcher: MailFetching {
    private let credentials: any CredentialProviding
    private let timeout: TimeInterval
    private let maxMessages: Int
    private let junkFolders: JunkFolderCache
    private let makeSession: @Sendable (MailboxConfig) -> any MailSession

    /// Envelopes requested per UID FETCH while walking back from the newest UID.
    static let envelopeBatchSize = 25
    /// Messages whose bodies are requested in one pipelined burst.
    static let bodyBatchSize = 5

    /// - Parameters:
    ///   - credentials: Supplies the password or OAuth access token per mailbox.
    ///   - timeout: Wall-clock budget in seconds for one `recentMessages` call (credential lookup,
    ///     connect, login, both folders). On expiry the connection is dropped and the messages read so
    ///     far are returned; with none read yet, `MailFetchError.timedOut` is thrown.
    ///   - maxMessages: Upper bound on messages read per call, across both folders: the newest INBOX
    ///     messages first, then the newest junk-folder messages up to what is left.
    public init(credentials: any CredentialProviding, timeout: TimeInterval, maxMessages: Int = 50) {
        self.init(credentials: credentials, timeout: timeout, maxMessages: maxMessages,
                  junkFolders: .shared) { mailbox in
            SwiftMailSession(server: IMAPServer(
                host: mailbox.imapHost,
                port: mailbox.imapPort,
                // 993 is IMAP over implicit TLS; any other port must upgrade with STARTTLS. Never plaintext.
                transportSecurity: mailbox.imapPort == 993 ? .implicitTLS : .startTLS
            ))
        }
    }

    /// Test seam: `makeSession` supplies the IMAP session for a mailbox; `junkFolders` defaults to a
    /// fresh cache so tests do not share discovered folders.
    init(credentials: any CredentialProviding, timeout: TimeInterval, maxMessages: Int = 50,
         junkFolders: JunkFolderCache = JunkFolderCache(),
         makeSession: @escaping @Sendable (MailboxConfig) -> any MailSession) {
        self.credentials = credentials
        self.timeout = timeout
        self.maxMessages = maxMessages
        self.junkFolders = junkFolders
        self.makeSession = makeSession
    }

    public func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage] {
        let session = makeSession(mailbox)
        let collected = CollectedMessages()
        let credentials = self.credentials
        let maxMessages = self.maxMessages
        let junkFolders = self.junkFolders
        do {
            try await Deadline.run(
                seconds: timeout,
                operation: {
                    try await Self.fetch(session: session, mailbox: mailbox, since: since,
                                         credentials: credentials, maxMessages: maxMessages,
                                         junkFolders: junkFolders, into: collected)
                },
                onTimeout: { await session.disconnect() }
            )
            return collected.newestFirst()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Budget over or a later command failed: keep what was already read.
            let partial = collected.newestFirst()
            if partial.isEmpty { throw error }
            return partial
        }
    }

    // MARK: - Fetch steps

    private static func fetch(session: any MailSession, mailbox: MailboxConfig, since: Date,
                              credentials: any CredentialProviding, maxMessages: Int,
                              junkFolders: JunkFolderCache, into collected: CollectedMessages) async throws {
        do {
            let credential = try await credentials.credential(for: mailbox)
            try await session.open(username: mailbox.username, credential: credential)
            try await session.examine("INBOX")
            try await readRecent(.inbox, session: session, mailbox: mailbox, since: since,
                                 limit: maxMessages, into: collected)
            let room = maxMessages - collected.count
            if room > 0, let junk = try await junkFolder(session: session, mailbox: mailbox, cache: junkFolders) {
                do {
                    try await session.examine(junk.name)
                } catch {
                    // A remembered folder may have been renamed or deleted: look it up again next time.
                    if junk.fromCache, !(error is CancellationError) { junkFolders.remove(for: mailbox) }
                    throw error
                }
                try await readRecent(.junk, session: session, mailbox: mailbox, since: since,
                                     limit: room, into: collected)
            }
            await session.logout()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    /// The junk folder to read: the remembered one, else the result of one IMAP LIST, which is then
    /// remembered (including "none") for this mailbox until the process ends.
    static func junkFolder(session: any MailSession, mailbox: MailboxConfig,
                           cache: JunkFolderCache) async throws -> (name: String, fromCache: Bool)? {
        switch cache.entry(for: mailbox) {
        case .found(let name)?:
            return (name, true)
        case .notFound?:
            return nil
        case nil:
            try Task.checkCancellation()
            let listed = try await session.listFolders()
            // A reply that arrives after the budget ended belongs to an abandoned fetch: remember nothing.
            try Task.checkCancellation()
            guard let name = JunkFolder.name(in: listed.mailboxes, namespaces: listed.namespaces) else {
                cache.store(.notFound, for: mailbox)
                return nil
            }
            cache.store(.found(name), for: mailbox)
            return (name, false)
        }
    }

    /// Reads the messages of the examined folder received at or after `since`, at most `limit`,
    /// newest first, into `collected`.
    static func readRecent(_ folder: MailFolder, session: any MailSession, mailbox: MailboxConfig, since: Date,
                           limit: Int, into collected: CollectedMessages) async throws {
        try Task.checkCancellation()
        let found = try await session.searchUIDs(since: FetchLogic.searchDay(for: since))
        let infos = try await recentInfos(session: session, uids: found, since: since, limit: limit)
        try await readBodies(session: session, infos: infos, folder: folder, mailbox: mailbox, into: collected)
    }

    /// Envelopes of the messages received at or after `since`, newest UID first, at most `limit`.
    /// UIDs grow with arrival order (RFC 3501 §2.3.1.1), so the walk stops after the first batch whose
    /// oldest message is already older than `since`.
    static func recentInfos(session: any MailSession, uids: [UID], since: Date, limit: Int) async throws -> [(uid: UID, info: MessageInfo)] {
        var recent: [(uid: UID, info: MessageInfo)] = []
        let newestFirst = uids.sorted(by: >)
        var start = 0
        while start < newestFirst.count, recent.count < limit {
            try Task.checkCancellation()
            let batch = Array(newestFirst[start..<min(start + envelopeBatchSize, newestFirst.count)])
            start += batch.count
            let infos = try await session.fetchInfos(batch)
            let byUID = Dictionary(infos.compactMap { info in info.uid.map { ($0, info) } }, uniquingKeysWith: { first, _ in first })
            var reachedOlder = false
            for uid in batch {
                guard let info = byUID[uid] else { continue }
                if FetchLogic.isRecent(info, since: since) {
                    if recent.count < limit { recent.append((uid, info)) }
                } else {
                    reachedOlder = true
                }
            }
            if reachedOlder, let oldest = batch.last, let info = byUID[oldest], !FetchLogic.isRecent(info, since: since) {
                break
            }
        }
        return recent
    }

    /// Reads bodies newest first, `bodyBatchSize` messages per pipelined burst: text/plain when present
    /// and non-empty, else text/html converted to text. Each finished message goes into `collected`.
    static func readBodies(session: any MailSession, infos: [(uid: UID, info: MessageInfo)], folder: MailFolder,
                           mailbox: MailboxConfig, into collected: CollectedMessages) async throws {
        var start = 0
        while start < infos.count {
            try Task.checkCancellation()
            let batch = Array(infos[start..<min(start + bodyBatchSize, infos.count)])
            start += batch.count
            var texts: [UID: String] = [:]
            var pending = batch.map { (uid: $0.uid, candidates: FetchLogic.bodyCandidates(for: $0.info)[...]) }
            // At most two rounds: the preferred part, then the HTML part where plain text was empty.
            while pending.contains(where: { !$0.candidates.isEmpty }) {
                try Task.checkCancellation()
                let requests = pending.compactMap { entry in entry.candidates.first.map { (uid: entry.uid, section: $0.part.section) } }
                let fetched = try await session.fetchParts(requests)
                var next: [(uid: UID, candidates: ArraySlice<(part: MessagePart, kind: FetchLogic.BodyKind)>)] = []
                for entry in pending {
                    guard let candidate = entry.candidates.first else { continue }
                    let raw = fetched[entry.uid]?.first(where: { $0.section == candidate.part.section })?.data
                    if let raw, let text = FetchLogic.text(of: candidate.part, rawData: raw, kind: candidate.kind),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        texts[entry.uid] = text
                    } else if entry.candidates.count > 1 {
                        next.append((entry.uid, entry.candidates.dropFirst()))
                    }
                }
                pending = next
            }
            for (uid, info) in batch {
                collected.append(FetchLogic.makeMessage(info: info, uid: uid, folder: folder, mailbox: mailbox,
                                                        bodyText: texts[uid] ?? ""))
            }
        }
    }
}

/// Messages read so far by one `recentMessages` call; safe to read while the fetch is still running.
final class CollectedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [FetchedMessage] = []

    func append(_ message: FetchedMessage) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.count
    }

    /// Both folders merged, newest (server receipt time) first.
    func newestFirst() -> [FetchedMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages.sorted { $0.date > $1.date }
    }
}

// MARK: - IMAP session

/// The IMAP commands `IMAPMailFetcher` uses, so the fetch order and budget handling can be tested
/// without a server. `SwiftMailSession` is the live implementation. There is deliberately no command
/// that opens a folder read-write or changes flags or folders (SELECT, STORE, COPY, MOVE, EXPUNGE).
protocol MailSession: Sendable {
    /// Connects and authenticates.
    func open(username: String, credential: MailCredential) async throws
    /// Opens `folder` read-only (EXAMINE); later searches and fetches read from it.
    func examine(_ folder: String) async throws
    /// Every folder with its attributes (`LIST "" "*"`), and the namespaces learned at login.
    func listFolders() async throws -> FolderList
    /// UIDs in the examined folder matching `SEARCH SINCE <day>`.
    func searchUIDs(since day: Date) async throws -> [UID]
    /// Envelope, INTERNALDATE and body structure of `uids`, in one UID FETCH.
    func fetchInfos(_ uids: [UID]) async throws -> [MessageInfo]
    /// Still transfer-encoded part bodies, fetched with `BODY.PEEK` in one pipelined burst.
    func fetchParts(_ requests: [(uid: UID, section: Section)]) async throws -> [UID: [(section: Section, data: Data)]]
    /// Polite LOGOUT; errors are ignored.
    func logout() async
    /// Drops the connection; errors are ignored.
    func disconnect() async
}

/// A LIST reply: `Mailbox.Info` as SwiftMail 1.12.0 builds it (Models/Mailbox.swift L109-L113).
struct FolderList: Sendable {
    var mailboxes: [Mailbox.Info]
    var namespaces: NamespaceResponse?
}

/// `MailSession` on SwiftMail 1.12.0's `IMAPServer`.
struct SwiftMailSession: MailSession {
    let server: IMAPServer

    func open(username: String, credential: MailCredential) async throws {
        try await server.connect()
        switch credential {
        case .password(let password):
            try await server.login(username: username, password: password)
        case .xoauth2(let accessToken):
            try await server.authenticateXOAUTH2(email: username, accessToken: accessToken)
        }
    }

    func examine(_ folder: String) async throws {
        // EXAMINE, never SELECT (IMAPServer+Mailbox.swift L59-L63, ExamineMailboxCommand.swift L26).
        try await server.examineMailbox(folder)
    }

    func listFolders() async throws -> FolderList {
        // Plain LIST (IMAPServer+Namespace.swift L32-L56); `JunkFolder` explains why not the SPECIAL-USE variant.
        let mailboxes = try await server.listMailboxes()
        return FolderList(mailboxes: mailboxes, namespaces: await server.namespaces)
    }

    func searchUIDs(since day: Date) async throws -> [UID] {
        // `sortCriteria: []` does not issue SORT (Capability+Sort.swift returns false for empty criteria).
        try await server.search(criteria: [.since(day)], sortCriteria: [], calendar: FetchLogic.searchCalendar)
    }

    func fetchInfos(_ uids: [UID]) async throws -> [MessageInfo] {
        guard !uids.isEmpty else { return [] }
        return try await server.fetchMessageInfosBulk(using: MessageIdentifierSet<UID>(uids),
                                                      options: [.envelope, .internalDate, .bodyStructure])
    }

    func fetchParts(_ requests: [(uid: UID, section: Section)]) async throws -> [UID: [(section: Section, data: Data)]] {
        guard !requests.isEmpty else { return [:] }
        return try await server.fetchPartsPipelined(parts: requests)
    }

    func logout() async {
        try? await server.logout()
    }

    func disconnect() async {
        try? await server.disconnect()
    }
}
