import Foundation
import SkiPassExtraction
import SkiPassModels
import SwiftMail

/// Server-independent pieces of `IMAPMailFetcher`, kept separate so they can be unit-tested.
enum FetchLogic {
    /// IMAP SEARCH SINCE matches on the internal date "disregarding time and timezone"
    /// (RFC 3501 §6.4.4), i.e. it is day-granular in the server's own zone. Searching from the
    /// previous UTC day therefore never misses a message received at or after `since`
    /// (UTC offsets are within ±14 h); `isRecent` then applies the exact cut.
    static let searchCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func searchDay(for since: Date) -> Date {
        searchCalendar.date(byAdding: .day, value: -1, to: since) ?? since.addingTimeInterval(-86_400)
    }

    /// Exact recency cut on the server delivery time (INTERNALDATE), falling back to the
    /// sender's Date header only when the server did not return INTERNALDATE.
    static func isRecent(_ info: MessageInfo, since: Date) -> Bool {
        guard let received = info.internalDate ?? info.date else { return false }
        return received >= since
    }

    /// `"<mailboxID>:<uid>"` (CONTRACTS §3).
    static func messageID(mailboxID: UUID, uid: UID) -> String {
        "\(mailboxID.uuidString):\(uid.value)"
    }

    enum BodyKind: Equatable { case plain, html }

    /// Body parts to try, in order: text/plain first, then text/html. Uses SwiftMail's own
    /// body selection (`Message.findTextBodyPart` / `findHtmlBodyPart`), which skips
    /// attachments and parts of attached messages.
    static func bodyCandidates(for info: MessageInfo) -> [(part: MessagePart, kind: BodyKind)] {
        let message = Message(header: info, parts: info.parts)
        var candidates: [(MessagePart, BodyKind)] = []
        if let plain = message.findTextBodyPart() { candidates.append((plain, .plain)) }
        if let html = message.findHtmlBodyPart() { candidates.append((html, .html)) }
        return candidates
    }

    /// Decodes a fetched (still transfer-encoded) part body to plain text.
    static func text(of part: MessagePart, rawData: Data, kind: BodyKind) -> String? {
        var filled = part
        filled.data = rawData
        guard let decoded = filled.textContent else { return nil }
        switch kind {
        case .plain: return decoded
        case .html: return HTMLText.plainText(fromHTML: decoded)
        }
    }

    /// `date` is the server receipt time (INTERNALDATE), the clock the recency cut uses; the
    /// sender-controlled `Date:` header is only a fallback (a future `Date:` header must not make
    /// a message look newest in the local fallback or in the server's tie-break).
    static func makeMessage(info: MessageInfo, uid: UID, mailbox: MailboxConfig, bodyText: String) -> FetchedMessage {
        FetchedMessage(
            id: messageID(mailboxID: mailbox.id, uid: uid),
            mailboxAddress: mailbox.address,
            from: info.from ?? "",
            to: info.to.joined(separator: ", "),
            subject: info.subject ?? "",
            date: info.internalDate ?? info.date ?? Date(timeIntervalSince1970: 0),
            bodyText: bodyText
        )
    }
}
