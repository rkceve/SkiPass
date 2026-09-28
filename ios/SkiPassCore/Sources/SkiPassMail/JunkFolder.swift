import Foundation
import SkiPassModels
import SwiftMail

/// The folders `IMAPMailFetcher` reads. The raw value is the folder's key in message ids
/// (`"<mailboxID>:<folder>:<uid>"`, docs/API.md): a fixed word, never the server's folder name, which
/// can contain ":" and modified UTF-7 and would reach the server in every judge request.
enum MailFolder: String, Sendable {
    case inbox
    case junk
}

/// Finds the account's junk (spam) folder in an IMAP LIST reply.
///
/// SwiftMail 1.12.0 API used (Sources/SwiftMail/IMAP/...):
/// - `IMAPServer.listMailboxes(wildcard:)` (IMAPServer+Namespace.swift L32-L56) sends a plain
///   `LIST "" "*"` (one per namespace pattern when NAMESPACE was fetched at login) and returns
///   `[Mailbox.Info]`.
/// - `Mailbox.Info.attributes` maps a server-sent RFC 6154 `\Junk` to `.junk`
///   (Models/Mailbox.swift L45, L64-L94) and `\Noselect` to `.noSelect` (L67; `isSelectable`, L123).
/// - `Mailbox.Info.name` is the listed name byte for byte (L109-L113), and EXAMINE sends it back
///   unchanged (ExamineMailboxCommand.swift L26), so a modified UTF-7 name round-trips.
///
/// `IMAPServer.listSpecialUseMailboxes()` (IMAPServer+SpecialUse.swift L21) is not used: it adds a
/// second LIST, `LIST "" "*" RETURN (SPECIAL-USE)` (L50), which Gmail has been reported to reject with
/// BAD (https://www.limilabs.com/blog/gmail-special-use-capability-is-broken), and on servers without
/// the SPECIAL-USE capability it marks every folder whose name merely contains "junk" or "spam"
/// (L133-L136). RFC 6154 §2 lets a server include the special-use attributes in a plain LIST reply,
/// and Gmail, whose localized spam folder (e.g. "[Gmail]/&j,dg0TDhMPww6w-") can only be found by
/// attribute, does so in every LIST reply
/// (https://developers.google.com/workspace/gmail/imap/imap-extensions).
enum JunkFolder {
    /// Folder names tried, in this order, when no listed folder carries `\Junk`
    /// (compared case-insensitively, as listed and relative to the server's namespace prefix).
    static let fallbackNames = ["[Gmail]/Spam", "Junk", "Junk E-mail", "Junk Email", "Spam", "Bulk Mail"]

    /// The name to EXAMINE, or nil when the account has no recognizable junk folder.
    /// INBOX and folders that cannot be selected are never chosen.
    static func name(in mailboxes: [Mailbox.Info], namespaces: NamespaceResponse? = nil) -> String? {
        let selectable = mailboxes.filter { mailbox in
            mailbox.isSelectable && mailbox.name.caseInsensitiveCompare("INBOX") != .orderedSame
        }
        if let flagged = selectable.first(where: { $0.attributes.contains(.junk) }) {
            return flagged.name
        }
        for fallback in fallbackNames {
            if let match = selectable.first(where: { matches($0.name, fallback, namespaces: namespaces) }) {
                return match.name
            }
        }
        return nil
    }

    private static func matches(_ listed: String, _ expected: String, namespaces: NamespaceResponse?) -> Bool {
        if listed.caseInsensitiveCompare(expected) == .orderedSame { return true }
        // e.g. "INBOX.Junk" under the personal namespace "INBOX." (NamespaceResponse.relativeMailboxName,
        // Models/Namespace.swift L82-L96).
        guard let relative = namespaces?.relativeMailboxName(from: listed), relative != listed else { return false }
        return relative.caseInsensitiveCompare(expected) == .orderedSame
    }
}

/// The junk folder found per mailbox, kept in memory for the life of the process so the IMAP LIST
/// round trip is paid once, not on every fill. "No junk folder" is remembered too.
/// Keyed by the whole `MailboxConfig`, so an edited host or username is looked up again.
final class JunkFolderCache: @unchecked Sendable {
    enum Entry: Equatable, Sendable {
        /// The folder name to EXAMINE.
        case found(String)
        /// The last LIST showed no junk folder.
        case notFound
    }

    /// The cache the extension uses.
    static let shared = JunkFolderCache()

    private let lock = NSLock()
    private var entries: [MailboxConfig: Entry] = [:]

    func entry(for mailbox: MailboxConfig) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[mailbox]
    }

    func store(_ entry: Entry, for mailbox: MailboxConfig) {
        lock.lock()
        entries[mailbox] = entry
        lock.unlock()
    }

    func remove(for mailbox: MailboxConfig) {
        lock.lock()
        entries[mailbox] = nil
        lock.unlock()
    }
}
