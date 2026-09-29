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
/// - The credential is resolved once (one OAuth token refresh), then INBOX and the junk folder
///   (RFC 6154 `\Junk`, else a known name; see `JunkFolder`) are read at the same time on two separate
///   connections (two `IMAPServer`s), within the same time budget and recency window. A folder that
///   fails does not stop the other one. The junk folder is found with one IMAP LIST per mailbox and
///   process (`JunkFolderCache`), on the junk connection.
/// - Each folder has its own message cap, so a busy INBOX cannot leave no room for the junk folder.
/// - Message ids carry the folder (`"<mailboxID>:<folder>:<uid>"`, `FetchLogic.messageID`), because
///   UIDs are only unique within a folder.
///
/// Order and budget:
/// - Envelopes are fetched newest UID first, in batches, and the exact recency cut (INTERNALDATE) is
///   applied before anything is capped; fetching stops once a batch reaches messages older than `since`.
/// - Bodies are fetched newest first, several messages per pipelined burst
///   (`IMAPServer.fetchPartsPipelined`, IMAPServer+Fetch.swift L94), and every finished message is kept.
/// - The result is both folders merged, newest (server receipt time) first.
/// - When the time budget ends (the fetcher's own `timeout`, or the caller's earlier
///   `MailFetchContext.deadline`), the messages read so far from either folder are returned instead of
///   nothing, and both connections are dropped. The same cleanup runs when the caller cancels first
///   (Deadline.swift).
/// - Each step is recorded in `MailboxTraceRecorder.current` when the caller set one (diagnostics).
public struct IMAPMailFetcher: MailFetching {
    private let credentials: any CredentialProviding
    private let timeout: TimeInterval
    private let maxInboxMessages: Int
    private let maxJunkMessages: Int
    private let junkFolders: JunkFolderCache
    private let makeSession: @Sendable (MailboxConfig) -> any MailSession

    /// Envelopes requested per UID FETCH while walking back from the newest UID.
    static let envelopeBatchSize = 25
    /// Messages whose bodies are requested in one pipelined burst.
    static let bodyBatchSize = 5
    /// Default caps: recent INBOX messages and recent junk-folder messages read per call.
    public static let defaultMaxInboxMessages = 50
    public static let defaultMaxJunkMessages = 20

    /// - Parameters:
    ///   - credentials: Supplies the password or OAuth access token per mailbox.
    ///   - timeout: Wall-clock budget in seconds for one `recentMessages` call (credential lookup,
    ///     connect, login, both folders). On expiry the connections are dropped and the messages read so
    ///     far are returned; with none read yet, `MailFetchError.timedOut` is thrown.
    ///   - maxInboxMessages / maxJunkMessages: Upper bound on the newest recent messages read from
    ///     each folder.
    public init(credentials: any CredentialProviding, timeout: TimeInterval,
                maxInboxMessages: Int = IMAPMailFetcher.defaultMaxInboxMessages,
                maxJunkMessages: Int = IMAPMailFetcher.defaultMaxJunkMessages) {
        self.init(credentials: credentials, timeout: timeout, maxInboxMessages: maxInboxMessages,
                  maxJunkMessages: maxJunkMessages, junkFolders: .shared) { mailbox in
            SwiftMailSession(server: IMAPServer(
                host: mailbox.imapHost,
                port: mailbox.imapPort,
                // 993 is IMAP over implicit TLS; any other port must upgrade with STARTTLS. Never plaintext.
                transportSecurity: mailbox.imapPort == 993 ? .implicitTLS : .startTLS
            ))
        }
    }

    /// Test seam: `makeSession` supplies one IMAP connection per call (called twice per fetch: INBOX
    /// and junk folder); `junkFolders` defaults to a fresh cache so tests do not share discovered folders.
    init(credentials: any CredentialProviding, timeout: TimeInterval,
         maxInboxMessages: Int = IMAPMailFetcher.defaultMaxInboxMessages,
         maxJunkMessages: Int = IMAPMailFetcher.defaultMaxJunkMessages,
         junkFolders: JunkFolderCache = JunkFolderCache(),
         makeSession: @escaping @Sendable (MailboxConfig) -> any MailSession) {
        self.credentials = credentials
        self.timeout = timeout
        self.maxInboxMessages = maxInboxMessages
        self.maxJunkMessages = maxJunkMessages
        self.junkFolders = junkFolders
        self.makeSession = makeSession
    }

    /// Seconds this call may take: `timeout`, or less when the caller's deadline comes first.
    func effectiveTimeout(now: ContinuousClock.Instant = .now) -> TimeInterval {
        guard let deadline = MailFetchContext.deadline else { return timeout }
        let remaining = deadline - now
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        return max(0.1, min(timeout, seconds))
    }

    public func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage] {
        let inboxSession = makeSession(mailbox)
        let junkSession = makeSession(mailbox)
        let collected = CollectedMessages()
        let credentials = self.credentials
        let limits = FolderLimits(inbox: maxInboxMessages, junk: maxJunkMessages)
        let junkFolders = self.junkFolders
        let trace = MailboxTraceRecorder.current
        let seconds = effectiveTimeout()
        do {
            try await Deadline.run(
                seconds: seconds,
                operation: {
                    try await Self.fetch(inboxSession: inboxSession, junkSession: junkSession, mailbox: mailbox,
                                         since: since, credentials: credentials, limits: limits,
                                         junkFolders: junkFolders, into: collected)
                },
                onTimeout: {
                    await Self.disconnect(inboxSession, junkSession)
                }
            )
            return collected.newestFirst()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error as? MailFetchError == .timedOut {
                let ms = Int(seconds * 1_000)
                let kept = collected.count
                trace?.update { $0.error = "fetch deadline reached after \(ms) ms" }
                trace?.log("fetch deadline reached after \(ms) ms, \(kept) msgs kept")
            }
            // Budget over or a later command failed: keep what was already read.
            let partial = collected.newestFirst()
            if partial.isEmpty { throw error }
            return partial
        }
    }

    // MARK: - Fetch steps

    struct FolderLimits: Sendable {
        var inbox: Int
        var junk: Int
    }

    private static func disconnect(_ first: any MailSession, _ second: any MailSession) async {
        async let one: Void = first.disconnect()
        async let two: Void = second.disconnect()
        _ = await (one, two)
    }

    private static func fetch(inboxSession: any MailSession, junkSession: any MailSession, mailbox: MailboxConfig,
                              since: Date, credentials: any CredentialProviding, limits: FolderLimits,
                              junkFolders: JunkFolderCache, into collected: CollectedMessages) async throws {
        let trace = MailboxTraceRecorder.current
        let credentialStart = ContinuousClock.now
        let credential: MailCredential
        do {
            credential = try await credentials.credential(for: mailbox)
            let result = StageResult(ok: true, ms: Diagnostics.milliseconds(since: credentialStart))
            trace?.update { $0.credential = result }
            trace?.log("credential \(result.summary)")
        } catch {
            let result = StageResult(ok: false, ms: Diagnostics.milliseconds(since: credentialStart),
                                     error: Diagnostics.errorSummary(error))
            trace?.update { $0.credential = result }
            trace?.log("credential \(result.summary)")
            await disconnect(inboxSession, junkSession)
            throw error
        }

        async let inboxError = readInbox(session: inboxSession, mailbox: mailbox, credential: credential,
                                         since: since, limit: limits.inbox, into: collected)
        async let junkError = readJunk(session: junkSession, mailbox: mailbox, credential: credential,
                                       since: since, limit: limits.junk, cache: junkFolders, into: collected)
        let errors = await (inboxError, junkError)
        // One folder failing still returns the other's messages.
        if let error = errors.0 ?? errors.1, collected.count == 0 {
            throw error
        }
    }

    /// Reads INBOX on its own connection. Returns the error instead of throwing, so the junk folder
    /// keeps going.
    static func readInbox(session: any MailSession, mailbox: MailboxConfig, credential: MailCredential,
                          since: Date, limit: Int, into collected: CollectedMessages) async -> (any Error)? {
        let folder = FolderProgress(kind: .inbox)
        do {
            try await folder.connect(session: session, mailbox: mailbox, credential: credential)
            folder.stage("examining", name: "INBOX")
            try await session.examine("INBOX")
            try await readRecent(.inbox, session: session, mailbox: mailbox, since: since, limit: limit,
                                 progress: folder, into: collected)
            folder.finish()
            await session.logout()
            return nil
        } catch {
            folder.fail(error)
            await session.disconnect()
            return error
        }
    }

    /// Finds and reads the junk folder on its own connection. Returns the error instead of throwing.
    static func readJunk(session: any MailSession, mailbox: MailboxConfig, credential: MailCredential,
                         since: Date, limit: Int, cache: JunkFolderCache,
                         into collected: CollectedMessages) async -> (any Error)? {
        let folder = FolderProgress(kind: .junk)
        guard limit > 0 else {
            folder.finish()
            return nil
        }
        do {
            try await folder.connect(session: session, mailbox: mailbox, credential: credential)
            folder.stage("listing")
            guard let junk = try await junkFolder(session: session, mailbox: mailbox, cache: cache) else {
                folder.notFound()
                await session.logout()
                return nil
            }
            folder.stage("examining", name: junk.name)
            do {
                try await session.examine(junk.name)
            } catch {
                // A remembered folder may have been renamed or deleted: look it up again next time.
                if junk.fromCache, !(error is CancellationError) { cache.remove(for: mailbox) }
                throw error
            }
            try await readRecent(.junk, session: session, mailbox: mailbox, since: since, limit: limit,
                                 progress: folder, into: collected)
            folder.finish()
            await session.logout()
            return nil
        } catch {
            folder.fail(error)
            await session.disconnect()
            return error
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
                           limit: Int, progress: FolderProgress? = nil, into collected: CollectedMessages) async throws {
        try Task.checkCancellation()
        progress?.stage("searching")
        let found = try await session.searchUIDs(since: FetchLogic.searchDay(for: since))
        progress?.stage("envelopes")
        let infos = try await recentInfos(session: session, uids: found, since: since, limit: limit)
        progress?.stage("bodies")
        try await readBodies(session: session, infos: infos, folder: folder, mailbox: mailbox,
                             progress: progress, into: collected)
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
                           mailbox: MailboxConfig, progress: FolderProgress? = nil,
                           into collected: CollectedMessages) async throws {
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
            progress?.add(messages: batch.count)
        }
    }
}

/// Writes one folder's progress into `MailboxTraceRecorder.current` (no-op without a recorder), so a
/// trace shows the step a folder was on when the budget ended.
final class FolderProgress: @unchecked Sendable {
    private let kind: MailFolder
    private let trace: MailboxTraceRecorder?
    private let start = ContinuousClock.now

    init(kind: MailFolder, trace: MailboxTraceRecorder? = MailboxTraceRecorder.current) {
        self.kind = kind
        self.trace = trace
        update { $0.stage = "connecting" }
    }

    private var label: String { kind == .inbox ? "INBOX" : "junk" }

    private func update(_ body: (inout FolderTrace) -> Void) {
        guard let trace else { return }
        let kind = self.kind
        trace.update { mailbox in
            var folder = (kind == .inbox ? mailbox.inbox : mailbox.junk) ?? FolderTrace()
            body(&folder)
            if kind == .inbox {
                mailbox.inbox = folder
            } else {
                mailbox.junk = folder
            }
        }
    }

    /// Connects and authenticates, recording the result.
    func connect(session: any MailSession, mailbox: MailboxConfig, credential: MailCredential) async throws {
        let connectStart = ContinuousClock.now
        do {
            try await session.open(username: mailbox.username, credential: credential)
            let result = StageResult(ok: true, ms: Diagnostics.milliseconds(since: connectStart))
            update { $0.connect = result }
            trace?.log("\(label) connect+auth \(result.summary)")
        } catch {
            let result = StageResult(ok: false, ms: Diagnostics.milliseconds(since: connectStart),
                                     error: Diagnostics.errorSummary(error))
            update { $0.connect = result }
            trace?.log("\(label) connect+auth \(result.summary)")
            throw error
        }
    }

    func stage(_ stage: String, name: String? = nil) {
        update { folder in
            folder.stage = stage
            if let name {
                folder.name = name
                folder.found = true
            }
        }
    }

    func add(messages: Int) {
        update { $0.messages += messages }
    }

    func notFound() {
        let ms = Diagnostics.milliseconds(since: start)
        update { folder in
            folder.found = false
            folder.stage = "done"
            folder.ms = ms
        }
        trace?.log("\(label) folder not found (\(ms) ms)")
    }

    func finish() {
        let ms = Diagnostics.milliseconds(since: start)
        update { folder in
            folder.stage = "done"
            folder.ms = ms
        }
        if let trace {
            let snapshot = trace.snapshot
            let folder = kind == .inbox ? snapshot.inbox : snapshot.junk
            trace.log("\(label) \(folder?.summary ?? "done")")
        }
    }

    func fail(_ error: any Error) {
        let ms = Diagnostics.milliseconds(since: start)
        let summary = Diagnostics.errorSummary(error)
        update { folder in
            folder.error = summary
            folder.ms = ms
        }
        trace?.log("\(label) failed after \(ms) ms: \(summary)")
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
