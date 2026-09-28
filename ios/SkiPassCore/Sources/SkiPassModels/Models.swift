import Foundation

// Shared model types used by the app and the extension (docs/ARCHITECTURE.md §1).

public enum ProviderKind: String, Codable, Sendable, Hashable {
    case google
    case microsoft
    case imap

    /// Default IMAP endpoint for OAuth providers; nil for `.imap` (user-supplied).
    public var presetIMAPEndpoint: (host: String, port: Int)? {
        switch self {
        case .google: return ("imap.gmail.com", 993)
        case .microsoft: return ("outlook.office365.com", 993)
        case .imap: return nil
        }
    }
}

/// A registered mailbox. Contains no secrets; credentials live in the Keychain (docs/ARCHITECTURE.md §5).
public struct MailboxConfig: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var address: String
    public var kind: ProviderKind
    public var imapHost: String
    public var imapPort: Int
    public var username: String

    public init(id: UUID = UUID(), address: String, kind: ProviderKind,
                imapHost: String, imapPort: Int, username: String) {
        self.id = id
        self.address = address
        self.kind = kind
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.username = username
    }
}

/// One email reduced to text. `id` is "<mailboxID>:<folder>:<uid>" with folder `inbox` or `junk`
/// (docs/API.md); nothing parses it, it only has to be unique within one lookup.
public struct FetchedMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var mailboxAddress: String
    public var from: String
    public var to: String
    public var subject: String
    public var date: Date
    public var bodyText: String

    public init(id: String, mailboxAddress: String, from: String, to: String,
                subject: String, date: Date, bodyText: String) {
        self.id = id
        self.mailboxAddress = mailboxAddress
        self.from = from
        self.to = to
        self.subject = subject
        self.date = date
        self.bodyText = bodyText
    }

    /// Full message text as sent to the server/Jev (docs/API.md).
    public var judgeText: String {
        "From: \(from)\nTo: \(to)\nSubject: \(subject)\nDate: \(ISO8601DateFormatter().string(from: date))\n\n\(bodyText)"
    }
}

public struct CodeCandidate: Codable, Sendable, Hashable {
    public var message: FetchedMessage
    public var code: String

    public init(message: FetchedMessage, code: String) {
        self.message = message
        self.code = code
    }
}

public enum JudgeOutcome: Sendable, Hashable {
    case chosen(messageID: String, scores: [String: Double])
    case noMatch(scores: [String: Double])
    case quotaExhausted
}

public struct UsageSnapshot: Codable, Sendable, Hashable {
    public var plan: String
    public var used: Int
    public var limit: Int
    public var resetsAt: Date

    public init(plan: String, used: Int, limit: Int, resetsAt: Date) {
        self.plan = plan
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
    }
}

public protocol MailFetching: Sendable {
    /// Messages received at or after `since` in INBOX and the junk (spam) folder, newest first.
    /// Must not mark messages as read or move them.
    func recentMessages(for mailbox: MailboxConfig, since: Date) async throws -> [FetchedMessage]
}

public protocol CodeExtracting: Sendable {
    /// The one-time code in the message, or nil if the message carries none.
    func extractCode(from message: FetchedMessage) -> String?
}

public protocol CandidateJudging: Sendable {
    func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome
}

public protocol UsageReporting: Sendable {
    /// Counts one successful fill. Returns remaining fills.
    @discardableResult
    func reportFill(messageID: String) async throws -> Int
    func currentUsage() async throws -> UsageSnapshot
}
