import Foundation
@testable import SkiPassMail
import SkiPassModels
import SwiftMail
import XCTest

/// Junk folder discovery from IMAP LIST replies.
///
/// Fixtures are built the way SwiftMail 1.12.0's own tests build LIST results:
/// - `Mailbox.Info(name:attributes:hierarchyDelimiter:)` arrays, as in
///   Tests/SwiftIMAPTests/NamespaceResolutionTests.swift L52-L62 ("INBOX.Sent" with "." etc.);
/// - the "INBOX." personal namespace of NamespaceResolutionTests.swift L20-L34;
/// - the wire form `* LIST (\HasNoChildren) "/" "INBOX"` of Tests/SwiftIMAPTests/IMAPTestServer.swift L500.
/// Attributes are what SwiftMail makes of the wire flags (Sources/SwiftMail/IMAP/Models/Mailbox.swift
/// L56-L94): `\HasNoChildren` -> `.hasNoChildren`, `\Noselect` -> `.noSelect`, `\Junk` -> `.junk`;
/// `\All` and `\Important` have no SwiftMail attribute and map to nothing.
final class JunkFolderTests: XCTestCase {
    private func folder(_ name: String, _ attributes: Mailbox.Info.Attributes = [.hasNoChildren],
                        delimiter: String = "/") -> Mailbox.Info {
        Mailbox.Info(name: name, attributes: attributes, hierarchyDelimiter: delimiter)
    }

    /// Gmail's documented LIST reply (https://developers.google.com/workspace/gmail/imap/imap-extensions):
    /// ```
    /// * LIST (\HasNoChildren) "/" "INBOX"
    /// * LIST (\Noselect \HasChildren) "/" "[Gmail]"
    /// * LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail"
    /// * LIST (\HasNoChildren \Drafts) "/" "[Gmail]/Drafts"
    /// * LIST (\HasNoChildren \Important) "/" "[Gmail]/Important"
    /// * LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"
    /// * LIST (\HasNoChildren \Junk) "/" "[Gmail]/Spam"
    /// * LIST (\HasNoChildren \Flagged) "/" "[Gmail]/Starred"
    /// * LIST (\HasNoChildren \Trash) "/" "[Gmail]/Trash"
    /// ```
    static let gmailListing: [Mailbox.Info] = [
        Mailbox.Info(name: "INBOX", attributes: [.hasNoChildren], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]", attributes: [.noSelect, .hasChildren], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/All Mail", attributes: [.hasNoChildren], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Drafts", attributes: [.hasNoChildren, .drafts], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Important", attributes: [.hasNoChildren], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Sent Mail", attributes: [.hasNoChildren, .sent], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Spam", attributes: [.hasNoChildren, .junk], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Starred", attributes: [.hasNoChildren, .flagged], hierarchyDelimiter: "/"),
        Mailbox.Info(name: "[Gmail]/Trash", attributes: [.hasNoChildren, .trash], hierarchyDelimiter: "/"),
    ]

    // MARK: RFC 6154 \Junk

    func testGmailSpamIsFoundByItsJunkAttribute() {
        XCTAssertEqual(JunkFolder.name(in: Self.gmailListing), "[Gmail]/Spam")
    }

    /// A Gmail account in Japanese lists its spam folder as "[Gmail]/迷惑メール" in modified UTF-7
    /// (RFC 3501 §5.1.3). Only the attribute identifies it, and the name must be returned byte for byte
    /// so EXAMINE can send it back.
    func testLocalizedSpamFolderIsFoundByAttributeAndKeepsItsListedName() {
        let listing = [
            folder("INBOX"),
            folder("[Gmail]", [.noSelect, .hasChildren]),
            folder("[Gmail]/&MFkweTBmMG4w4TD8MOs-"),  // すべてのメール (All Mail)
            folder("[Gmail]/&MLQw33ux-", [.hasNoChildren, .trash]),  // ゴミ箱 (Trash)
            folder("[Gmail]/&j,dg0TDhMPww6w-", [.hasNoChildren, .junk]),  // 迷惑メール (Spam)
        ]
        XCTAssertEqual(JunkFolder.name(in: listing), "[Gmail]/&j,dg0TDhMPww6w-")
    }

    /// `* LIST (\HasNoChildren) "/" "Spam"` (a user folder) and `* LIST (\HasNoChildren \Junk) "/" "Junk Email"`.
    func testJunkAttributeWinsOverKnownNames() {
        let listing = [folder("INBOX"), folder("Spam"), folder("Junk"), folder("Junk Email", [.hasNoChildren, .junk])]
        XCTAssertEqual(JunkFolder.name(in: listing), "Junk Email")
    }

    func testJunkFolderThatCannotBeSelectedIsSkipped() {
        let listing = [folder("INBOX"), folder("Quarantine", [.noSelect, .junk]), folder("Spam")]
        XCTAssertEqual(JunkFolder.name(in: listing), "Spam")
    }

    func testInboxIsNeverTheJunkFolder() {
        XCTAssertNil(JunkFolder.name(in: [folder("INBOX", [.hasNoChildren, .junk])]))
        XCTAssertNil(JunkFolder.name(in: [folder("inbox")]))
    }

    // MARK: Known names (no \Junk advertised)

    func testKnownNamesAreUsedWithoutJunkAttribute() {
        for name in JunkFolder.fallbackNames {
            let listing = [folder("INBOX"), folder("Drafts"), folder("Sent"), folder(name), folder("Trash")]
            XCTAssertEqual(JunkFolder.name(in: listing), name)
        }
    }

    func testKnownNamesAreTriedInOrder() {
        XCTAssertEqual(JunkFolder.fallbackNames,
                       ["[Gmail]/Spam", "Junk", "Junk E-mail", "Junk Email", "Spam", "Bulk Mail"])
        XCTAssertEqual(JunkFolder.name(in: [folder("Spam"), folder("Junk")]), "Junk")
        XCTAssertEqual(JunkFolder.name(in: [folder("Spam"), folder("[Gmail]/Spam")]), "[Gmail]/Spam")
        XCTAssertEqual(JunkFolder.name(in: [folder("Junk Email"), folder("Junk E-mail")]), "Junk E-mail")
        XCTAssertEqual(JunkFolder.name(in: [folder("Bulk Mail"), folder("Spam")]), "Spam")
    }

    func testKnownNamesMatchCaseInsensitivelyAndKeepTheListedSpelling() {
        XCTAssertEqual(JunkFolder.name(in: [folder("INBOX"), folder("JUNK")]), "JUNK")
        XCTAssertEqual(JunkFolder.name(in: [folder("INBOX"), folder("bulk mail")]), "bulk mail")
    }

    /// Dovecot/Courier style: every folder under the personal namespace "INBOX." (as in SwiftMail's
    /// NamespaceResolutionTests.swift L20-L34 and L52-L62).
    func testKnownNamesMatchUnderThePersonalNamespacePrefix() {
        let namespaces = NamespaceResponse(personal: [Namespace(prefix: "INBOX.", delimiter: Character("."))],
                                           otherUsers: [], shared: [])
        let listing = [
            folder("INBOX", [.hasChildren], delimiter: "."),
            folder("INBOX.Sent", delimiter: "."),
            folder("INBOX.Drafts", delimiter: "."),
            folder("INBOX.Junk", delimiter: "."),
        ]
        XCTAssertEqual(JunkFolder.name(in: listing, namespaces: namespaces), "INBOX.Junk")
        // Without the namespace, "INBOX.Junk" is not guessed from its last component.
        XCTAssertNil(JunkFolder.name(in: listing))
    }

    func testSimilarNamesAreNotTaken() {
        let listing = [folder("INBOX"), folder("Not Spam"), folder("Spam Reports"), folder("Archive/Spam"),
                       folder("Junk-old"), folder("Spam", [.noSelect, .hasChildren])]
        XCTAssertNil(JunkFolder.name(in: listing))
    }

    func testNoJunkFolder() {
        XCTAssertNil(JunkFolder.name(in: []))
        XCTAssertNil(JunkFolder.name(in: [folder("INBOX"), folder("Sent"), folder("Trash")]))
    }

    // MARK: Cache

    func testCacheRemembersPerMailboxConfiguration() {
        let cache = JunkFolderCache()
        let mailbox = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                    imapPort: 993, username: "a@gmail.com")
        let other = MailboxConfig(address: "b@example.com", kind: .imap, imapHost: "imap.example.com",
                                  imapPort: 993, username: "b")
        XCTAssertNil(cache.entry(for: mailbox))

        cache.store(.found("[Gmail]/Spam"), for: mailbox)
        cache.store(.notFound, for: other)
        XCTAssertEqual(cache.entry(for: mailbox), .found("[Gmail]/Spam"))
        XCTAssertEqual(cache.entry(for: other), .notFound)

        // An edited host is a different server: look the folder up again.
        var edited = other
        edited.imapHost = "mail.example.com"
        XCTAssertNil(cache.entry(for: edited))

        cache.remove(for: mailbox)
        XCTAssertNil(cache.entry(for: mailbox))
        XCTAssertEqual(cache.entry(for: other), .notFound)
    }
}
