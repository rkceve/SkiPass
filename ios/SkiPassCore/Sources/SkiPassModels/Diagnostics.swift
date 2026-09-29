import Foundation

// On-device diagnostics of AutoFill requests and identity registration.
//
// The extension runs silently: every failure ends in a cancelled request that looks the same to the
// user. These records say which stage failed. They live in the shared App Group defaults, so the app
// can show them (the "Diagnostics" part of "How SkiPass works"), and each stage is also logged.
//
// Never recorded: email bodies, subjects, one-time codes, passwords or tokens. Mailbox addresses are
// masked (`r***@gmail.com`). Error texts are reduced to their type and case and scrubbed of anything
// that looks like a token (`Diagnostics.errorSummary`).

public enum Diagnostics {
    /// Shared defaults key of the last AutoFill traces (JSON array, newest last).
    public static let tracesKey = "diagnostics.autofill.v1"
    /// Shared defaults key of the App Group / keychain group the app resolved (written by the app).
    public static let appStorageKey = "diagnostics.app.v1"
    /// Shared defaults keys of the last identity registration, one per process (no cross-process
    /// read-modify-write on one key).
    public static let appRegistrationKey = "diagnostics.registration.app.v1"
    public static let extensionRegistrationKey = "diagnostics.registration.extension.v1"
    /// Traces kept.
    public static let maxTraces = 5

    /// `r***@gmail.com`: first character of the local part, then `***`, then the domain.
    public static func maskAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@") else {
            return trimmed.isEmpty ? "" : "\(trimmed.prefix(1))***"
        }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        return "\(local.prefix(1))***@\(domain)"
    }

    /// Short, secret-free description of an error: `URLError -1001`, `NSOSStatusErrorDomain -34018`,
    /// `ServerClientError.httpStatus(404)`, `OAuthError.missingStoredSecret(...)`.
    public static func errorSummary(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        if error is CancellationError {
            return "cancelled"
        }
        // Objective-C errors (AppAuth, Security): domain and code only; their userInfo can carry
        // server replies.
        if type(of: error) is NSError.Type {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code)"
        }
        let text = "\(type(of: error)).\(String(describing: error))"
        return redact(String(text.prefix(160)))
    }

    /// Replaces runs of 32 or more token-like characters (letters, digits, `_~+/=-`), e.g. OAuth
    /// tokens, JWT segments or base64 blobs, with `<redacted>`. `.` ends a run, so dotted type names
    /// such as `ServerClientError.httpStatus` stay readable.
    public static func redact(_ text: String) -> String {
        var result = ""
        var run = ""
        func flush() {
            result += run.count >= 32 ? "<redacted>" : run
            run = ""
        }
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber || "_~+/=-".contains(character) {
                run.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// Whole milliseconds between `start` and now.
    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        milliseconds(ContinuousClock.now - start)
    }

    public static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// The App Group and keychain group one process resolved.
public struct StorageSnapshot: Codable, Sendable, Equatable {
    public var bundleID: String?
    public var appGroup: String?
    public var keychainGroup: String?
    public var recordedAt: Date

    public init(bundleID: String?, appGroup: String?, keychainGroup: String?, recordedAt: Date) {
        self.bundleID = bundleID
        self.appGroup = appGroup
        self.keychainGroup = keychainGroup
        self.recordedAt = recordedAt
    }

    /// Same App Group and keychain group (the bundle IDs of app and extension always differ).
    public func sharesGroups(with other: StorageSnapshot) -> Bool {
        appGroup == other.appGroup && keychainGroup == other.keychainGroup
    }
}

/// Result of one identity registration (`IdentityRegistrar`) in the app or the extension.
public struct RegistrationRecord: Codable, Sendable, Equatable {
    /// "app" or "extension".
    public var process: String
    public var at: Date
    /// "registered", "removedAll", "storeDisabled", "failed" or "skipped".
    public var outcome: String
    public var count: Int?
    /// False when AutoFill is off for SkiPass (the identity store refuses identities).
    public var storeEnabled: Bool?
    /// Why it failed or was skipped.
    public var detail: String?

    public init(process: String, at: Date, outcome: String, count: Int? = nil,
                storeEnabled: Bool? = nil, detail: String? = nil) {
        self.process = process
        self.at = at
        self.outcome = outcome
        self.count = count
        self.storeEnabled = storeEnabled
        self.detail = detail
    }

    /// One line, e.g. `registered 142 identities`, `skipped: mailbox list unreadable`.
    public var summary: String {
        var text = outcome
        if let count { text += " \(count) identities" }
        if storeEnabled == false { text += " (AutoFill off)" }
        if let detail, !detail.isEmpty { text += ": \(detail)" }
        return text
    }
}

/// Outcome of one step (credential refresh, connect + authenticate).
public struct StageResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var ms: Int
    public var error: String?

    public init(ok: Bool, ms: Int, error: String? = nil) {
        self.ok = ok
        self.ms = ms
        self.error = error
    }

    public var summary: String {
        ok ? "ok \(ms) ms" : "failed \(ms) ms (\(error ?? "unknown"))"
    }
}

/// One folder (INBOX or the junk folder) of one mailbox, read on its own connection.
public struct FolderTrace: Codable, Sendable, Equatable {
    /// The folder name opened; nil while unknown or when no junk folder was found.
    public var name: String?
    /// False when the account has no recognizable junk folder.
    public var found: Bool?
    public var connect: StageResult?
    /// Last step reached: connecting, listing, examining, searching, envelopes, bodies, done.
    public var stage: String?
    /// Recent messages whose bodies were read so far.
    public var messages: Int
    public var ms: Int?
    public var error: String?

    public init(name: String? = nil, found: Bool? = nil, connect: StageResult? = nil, stage: String? = nil,
                messages: Int = 0, ms: Int? = nil, error: String? = nil) {
        self.name = name
        self.found = found
        self.connect = connect
        self.stage = stage
        self.messages = messages
        self.ms = ms
        self.error = error
    }

    public var summary: String {
        var parts: [String] = []
        if found == false {
            parts.append("not found")
        } else if let name {
            parts.append("\"\(name)\"")
        }
        if let connect { parts.append("connect \(connect.summary)") }
        parts.append("\(messages) msgs")
        if let ms { parts.append("\(ms) ms") }
        if let error {
            parts.append("error \(error) at \(stage ?? "start")")
        } else if let stage, stage != "done" {
            parts.append("stopped at \(stage)")
        }
        return parts.joined(separator: ", ")
    }
}

/// One mailbox in one fetch round.
public struct MailboxTrace: Codable, Sendable, Equatable {
    /// Masked address (`r***@gmail.com`).
    public var mailbox: String
    public var kind: String
    /// 1 = first fetch, 2 = the retry after the delivery wait.
    public var round: Int
    public var credential: StageResult?
    public var inbox: FolderTrace?
    public var junk: FolderTrace?
    /// Messages handed to extraction.
    public var messages: Int?
    public var ms: Int?
    public var error: String?

    public init(mailbox: String, kind: String, round: Int) {
        self.mailbox = mailbox
        self.kind = kind
        self.round = round
    }

    public var summaryLines: [String] {
        var head = "Mailbox \(mailbox) (\(kind)), round \(round):"
        if let messages { head += " \(messages) msgs" }
        if let ms { head += " in \(ms) ms" }
        if let error { head += " — \(error)" }
        var lines = [head]
        if let credential { lines.append("  credential \(credential.summary)") }
        if let inbox { lines.append("  INBOX: \(inbox.summary)") }
        if let junk { lines.append("  junk: \(junk.summary)") }
        return lines
    }
}

/// The judge step.
public struct JudgeTrace: Codable, Sendable, Equatable {
    /// "server", "local" (on-device fallback rule) or "none".
    public var source: String?
    /// Why the server was not used, when the local rule decided.
    public var serverError: String?
    /// "chosen", "noMatch", "quotaExhausted", "error", "chosenUnknown".
    public var outcome: String?
    /// Message id `<mailboxID>:<folder>:<uid>` (no content).
    public var chosenID: String?
    public var error: String?
    public var ms: Int?

    public init(source: String? = nil, serverError: String? = nil, outcome: String? = nil,
                chosenID: String? = nil, error: String? = nil, ms: Int? = nil) {
        self.source = source
        self.serverError = serverError
        self.outcome = outcome
        self.chosenID = chosenID
        self.error = error
        self.ms = ms
    }

    public var summary: String {
        var parts = ["Judge: \(outcome ?? "?")"]
        if let source { parts.append("via \(source)") }
        if let chosenID { parts.append("id \(chosenID)") }
        if let error { parts.append("error \(error)") }
        if let serverError { parts.append("server error \(serverError)") }
        if let ms { parts.append("\(ms) ms") }
        return parts.joined(separator: ", ")
    }
}

/// One AutoFill request, from the entry point to fill or cancel.
public struct AutoFillTrace: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    /// "noUI", "credentialList", "interface" or "textToInsert".
    public var entryPoint: String
    /// Service identifier (site domain) from the request; nil for text insertion.
    public var service: String?
    /// Groups this (extension) process resolved.
    public var storage: StorageSnapshot?
    /// Whether they equal the groups the app resolved; nil when the app's record is not visible here.
    public var groupsMatchApp: Bool?
    public var mailboxCount: Int?
    public var mailboxError: String?
    public var mailboxes: [MailboxTrace]
    /// Fetch rounds run (2 when the retry after the delivery wait ran).
    public var rounds: Int
    public var candidateCount: Int?
    public var judge: JudgeTrace?
    /// "filled" or "cancelled".
    public var outcome: String?
    public var reason: String?
    public var totalMs: Int?

    public init(id: UUID = UUID(), startedAt: Date, entryPoint: String, service: String?) {
        self.id = id
        self.startedAt = startedAt
        self.entryPoint = entryPoint
        self.service = service
        self.mailboxes = []
        self.rounds = 0
    }

    /// Readable lines (the app's Diagnostics rows and the copied text).
    public var summaryLines: [String] {
        var lines: [String] = []
        let result = outcome.map { outcome in reason.map { "\(outcome) (\($0))" } ?? outcome } ?? "unfinished"
        var head = "Result: \(result)"
        if let totalMs { head += " after \(totalMs) ms" }
        lines.append(head)
        lines.append("Entry: \(entryPoint), service \(service ?? "none")")
        if let storage {
            let match = groupsMatchApp.map { $0 ? "same as app" : "DIFFERENT from app" } ?? "app record not visible"
            lines.append("Groups: app group \(storage.appGroup ?? "none"), keychain \(storage.keychainGroup ?? "default") (\(match))")
        }
        if let mailboxError {
            lines.append("Mailboxes: unreadable (\(mailboxError))")
        } else if let mailboxCount {
            lines.append("Mailboxes: \(mailboxCount)")
        }
        for mailbox in mailboxes { lines.append(contentsOf: mailbox.summaryLines) }
        if let candidateCount { lines.append("Code candidates: \(candidateCount) after \(rounds) round(s)") }
        if let judge { lines.append(judge.summary) }
        return lines
    }
}

/// Reads and writes the diagnostics records in one `UserDefaults` (live: the shared App Group
/// defaults of this process).
public final class DiagnosticsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Newest first.
    public func traces() -> [AutoFillTrace] {
        guard let data = defaults.data(forKey: Diagnostics.tracesKey),
              let list = try? Self.decoder.decode([AutoFillTrace].self, from: data)
        else { return [] }
        return list.reversed()
    }

    /// Keeps the newest `Diagnostics.maxTraces`.
    public func append(_ trace: AutoFillTrace) {
        lock.lock()
        defer { lock.unlock() }
        var list = (defaults.data(forKey: Diagnostics.tracesKey))
            .flatMap { try? Self.decoder.decode([AutoFillTrace].self, from: $0) } ?? []
        list.append(trace)
        if list.count > Diagnostics.maxTraces {
            list.removeFirst(list.count - Diagnostics.maxTraces)
        }
        if let data = try? Self.encoder.encode(list) {
            defaults.set(data, forKey: Diagnostics.tracesKey)
        }
    }

    public func appStorage() -> StorageSnapshot? {
        decode(StorageSnapshot.self, key: Diagnostics.appStorageKey)
    }

    public func setAppStorage(_ snapshot: StorageSnapshot) {
        encode(snapshot, key: Diagnostics.appStorageKey)
    }

    /// `process` "app" or "extension".
    public func registration(process: String) -> RegistrationRecord? {
        decode(RegistrationRecord.self, key: Self.registrationKey(process))
    }

    public func setRegistration(_ record: RegistrationRecord) {
        encode(record, key: Self.registrationKey(record.process))
    }

    private static func registrationKey(_ process: String) -> String {
        process == "app" ? Diagnostics.appRegistrationKey : Diagnostics.extensionRegistrationKey
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? Self.encoder.encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Recorders

/// Collects the trace of one AutoFill request while it runs. Available to the code the request
/// calls (fetcher, judge) through `AutoFillTraceRecorder.current`; `log` receives one line per stage.
public final class AutoFillTraceRecorder: @unchecked Sendable {
    @TaskLocal public static var current: AutoFillTraceRecorder?

    private let lock = NSLock()
    private var trace: AutoFillTrace
    private let start = ContinuousClock.now
    private let logLine: @Sendable (String) -> Void

    public init(trace: AutoFillTrace, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.trace = trace
        self.logLine = log
    }

    public var snapshot: AutoFillTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    public var elapsedMs: Int { Diagnostics.milliseconds(since: start) }

    public func update(_ body: (inout AutoFillTrace) -> Void) {
        lock.lock()
        body(&trace)
        lock.unlock()
    }

    /// Logs `message` prefixed with the trace's short id.
    public func log(_ message: String) {
        let id = snapshot.id.uuidString.prefix(8)
        logLine("[\(id)] \(message)")
    }
}

/// Collects the trace of one mailbox in one fetch round (`MailboxTraceRecorder.current` inside the
/// fetch). Folder updates may come from two connections at once.
public final class MailboxTraceRecorder: @unchecked Sendable {
    @TaskLocal public static var current: MailboxTraceRecorder?

    private let lock = NSLock()
    private var trace: MailboxTrace
    private let logLine: @Sendable (String) -> Void

    public init(trace: MailboxTrace, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.trace = trace
        self.logLine = log
    }

    public var snapshot: MailboxTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }

    public func update(_ body: (inout MailboxTrace) -> Void) {
        lock.lock()
        body(&trace)
        lock.unlock()
    }

    /// Logs `message` prefixed with the masked mailbox and round.
    public func log(_ message: String) {
        let current = snapshot
        logLine("\(current.mailbox) r\(current.round) \(message)")
    }
}

/// Per-call deadline for a mail fetch, set by the caller (the resolver's per-mailbox budget minus a
/// margin) so a fetcher with a longer own timeout still stops in time and returns what it read.
public enum MailFetchContext {
    @TaskLocal public static var deadline: ContinuousClock.Instant?
}
