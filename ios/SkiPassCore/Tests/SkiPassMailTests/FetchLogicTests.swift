import Foundation
@testable import SkiPassMail
import SkiPassModels
import SwiftMail
import XCTest

/// Part shapes mirror SwiftMail 1.12.0's own fixtures:
/// - Tests/SwiftIMAPTests/MessageBodyTests.swift L23-L41, L83-L101 (plain/html/attachment parts)
/// - Tests/SwiftIMAPTests/MessagePartBodyStructureTests.swift L82-L108 (message/rfc822 at "1",
///   inner text/plain at "1.1", text/html at "1.2")
/// - Tests/SwiftIMAPTests/QuotedPrintableTests.swift L103-L116 (quoted-printable samples)
final class FetchLogicTests: XCTestCase {
    private let utc = FetchLogic.searchCalendar

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func info(uid: UInt32 = 1, internalDate: Date? = nil, date: Date? = nil,
                      parts: [MessagePart] = []) -> MessageInfo {
        MessageInfo(sequenceNumber: SequenceNumber(uid), uid: UID(uid), subject: "Test Email",
                    from: "test@example.com", to: ["recipient@example.com"], date: date,
                    internalDate: internalDate, parts: parts)
    }

    // MARK: search window

    func testSearchDayIsPreviousUTCDay() {
        let since = date("2026-09-23T00:05:00Z")
        let day = FetchLogic.searchDay(for: since)
        XCTAssertEqual(utc.dateComponents([.year, .month, .day], from: day),
                       DateComponents(year: 2026, month: 9, day: 22))
    }

    func testSearchCalendarIsUTC() {
        XCTAssertEqual(FetchLogic.searchCalendar.timeZone.secondsFromGMT(), 0)
    }

    func testNewestUIDsKeepsHighest() {
        let uids = [UID(5), UID(1), UID(9), UID(7)]
        XCTAssertEqual(FetchLogic.newestUIDs(uids, limit: 2), [UID(7), UID(9)])
        XCTAssertEqual(FetchLogic.newestUIDs(uids, limit: 10), [UID(1), UID(5), UID(7), UID(9)])
        XCTAssertEqual(FetchLogic.newestUIDs(uids, limit: 0), [])
    }

    // MARK: exact recency cut

    func testIsRecentUsesInternalDate() {
        let since = date("2026-09-23T10:00:00Z")
        XCTAssertTrue(FetchLogic.isRecent(info(internalDate: since), since: since))
        XCTAssertTrue(FetchLogic.isRecent(info(internalDate: date("2026-09-23T10:03:00Z")), since: since))
        XCTAssertFalse(FetchLogic.isRecent(info(internalDate: date("2026-09-23T09:59:59Z")), since: since))
        // Internal date wins over a (sender-controlled) Date header.
        XCTAssertFalse(FetchLogic.isRecent(info(internalDate: date("2026-09-22T23:00:00Z"),
                                                date: date("2026-09-23T10:05:00Z")), since: since))
    }

    func testIsRecentFallsBackToDateHeaderThenRejects() {
        let since = date("2026-09-23T10:00:00Z")
        XCTAssertTrue(FetchLogic.isRecent(info(date: date("2026-09-23T10:01:00Z")), since: since))
        XCTAssertFalse(FetchLogic.isRecent(info(), since: since))
    }

    // MARK: ids and message assembly

    func testMessageIDFormat() {
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        XCTAssertEqual(FetchLogic.messageID(mailboxID: id, uid: UID(123)),
                       "E621E1F8-C36C-495A-93FC-0C247A3E6E5F:123")
    }

    func testMakeMessage() {
        let mailbox = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                    imapPort: 993, username: "a@gmail.com")
        let sent = date("2026-09-23T10:01:00Z")
        let message = FetchLogic.makeMessage(
            info: info(uid: 42, internalDate: date("2026-09-23T10:01:02Z"), date: sent),
            uid: UID(42), mailbox: mailbox, bodyText: "Your code is 123456")
        XCTAssertEqual(message.id, "\(mailbox.id.uuidString):42")
        XCTAssertEqual(message.mailboxAddress, "a@gmail.com")
        XCTAssertEqual(message.from, "test@example.com")
        XCTAssertEqual(message.to, "recipient@example.com")
        XCTAssertEqual(message.subject, "Test Email")
        XCTAssertEqual(message.bodyText, "Your code is 123456")
        // A2-09: the server receipt time (INTERNALDATE), not the sender-controlled Date header.
        XCTAssertEqual(message.date, date("2026-09-23T10:01:02Z"))
        XCTAssertNotEqual(message.date, sent)
    }

    func testMessageDateIgnoresFutureDateHeader() {
        let mailbox = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                    imapPort: 993, username: "a@gmail.com")
        let received = date("2026-09-23T10:01:02Z")
        let message = FetchLogic.makeMessage(
            info: info(uid: 7, internalDate: received, date: date("2026-09-24T10:00:00Z")),
            uid: UID(7), mailbox: mailbox, bodyText: "Save with code 1234")
        XCTAssertEqual(message.date, received)
    }

    func testMessageDateFallsBackToDateHeaderWithoutInternalDate() {
        let mailbox = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                    imapPort: 993, username: "a@gmail.com")
        let sent = date("2026-09-23T10:01:00Z")
        let message = FetchLogic.makeMessage(info: info(uid: 8, date: sent), uid: UID(8), mailbox: mailbox, bodyText: "")
        XCTAssertEqual(message.date, sent)
    }

    // MARK: body part selection

    func testPlainPreferredOverHTML() {
        let html = MessagePart(section: Section([1]), contentType: "text/html; charset=utf-8",
                               encoding: "quoted-printable")
        let plain = MessagePart(section: Section([2]), contentType: "text/plain; charset=utf-8",
                                encoding: "quoted-printable")
        let candidates = FetchLogic.bodyCandidates(for: info(parts: [html, plain]))
        XCTAssertEqual(candidates.map { $0.kind }, [.plain, .html])
        XCTAssertEqual(candidates.map { $0.part.section }, [Section([2]), Section([1])])
    }

    func testTextAttachmentIsNotABody() {
        let html = MessagePart(section: Section([1]), contentType: "text/html; charset=utf-8",
                               encoding: "quoted-printable")
        let attachment = MessagePart(section: Section([2]), contentType: "text/plain; charset=utf-8",
                                     disposition: "attachment", encoding: "base64", filename: "test.txt")
        let candidates = FetchLogic.bodyCandidates(for: info(parts: [html, attachment]))
        XCTAssertEqual(candidates.map { $0.kind }, [.html])
    }

    func testForwardedMessageBodiesAreIgnored() {
        let own = MessagePart(section: Section([1]), contentType: "text/plain")
        let forwarded = MessagePart(section: Section([2]), contentType: "message/rfc822")
        let innerPlain = MessagePart(section: Section([2, 1]), contentType: "text/plain")
        let innerHTML = MessagePart(section: Section([2, 2]), contentType: "text/html")
        let candidates = FetchLogic.bodyCandidates(for: info(parts: [own, forwarded, innerPlain, innerHTML]))
        XCTAssertEqual(candidates.map { $0.part.section }, [Section([1])])
    }

    func testNoTextPartsYieldsNoCandidates() {
        let image = MessagePart(section: Section([1]), contentType: "image/png")
        XCTAssertTrue(FetchLogic.bodyCandidates(for: info(parts: [image])).isEmpty)
    }

    // MARK: decoding

    func testQuotedPrintablePlainDecodes() {
        let part = MessagePart(section: Section([1]), contentType: "text/plain; charset=utf-8",
                               encoding: "quoted-printable")
        let text = FetchLogic.text(of: part, rawData: Data("3=3D2+1 Hello=20World".utf8), kind: .plain)
        XCTAssertEqual(text, "3=2+1 Hello World")
    }

    func testBase64PlainDecodes() {
        let part = MessagePart(section: Section([1]), contentType: "text/plain; charset=utf-8", encoding: "base64")
        let raw = Data("Your verification code is 482913".utf8).base64EncodedData()
        XCTAssertEqual(FetchLogic.text(of: part, rawData: raw, kind: .plain), "Your verification code is 482913")
    }

    func testHTMLIsConvertedToText() throws {
        let part = MessagePart(section: Section([1]), contentType: "text/html; charset=utf-8",
                               encoding: "quoted-printable")
        let raw = Data("<html><body>Test HTML content</body></html>".utf8)
        let text = try XCTUnwrap(FetchLogic.text(of: part, rawData: raw, kind: .html))
        XCTAssertTrue(text.contains("Test HTML content"))
        XCTAssertFalse(text.contains("<body>"))
    }
}
