@testable import SkiPassUI
import XCTest

final class EmailAddressFormatTests: XCTestCase {
    func testAcceptsOrdinaryAddresses() {
        for address in ["name@example.com", "info@myshop.jp", "hello@studio.co", "a.b+tag@mail.example.co.uk",
                        "Real.Name@gmail.com", "x@y.io"] {
            XCTAssertTrue(EmailAddressFormat.looksValid(address), address)
        }
    }

    /// A1-16: IDNA top-level domains are written in punycode.
    func testAcceptsPunycodeTopLevelDomains() {
        for address in ["user@example.xn--p1ai", "user@example.xn--wgv71a", "user@xn--80ak6aa92e.XN--P1AI"] {
            XCTAssertTrue(EmailAddressFormat.looksValid(address), address)
        }
        for text in ["user@example.xn--", "user@example.xn--p1ai-", "user@example.xn--p1_ai"] {
            XCTAssertFalse(EmailAddressFormat.looksValid(text), text)
        }
    }

    func testRejectsIncompleteOrMalformedText() {
        for text in ["", "name", "name@", "@example.com", "name@example", "name@example.", "name@.com",
                     "name@example.c", "name@@example.com", "na me@example.com", "name@exa mple.com",
                     "a@b@example.com", "name@example.c0m", "name@example..com"] {
            XCTAssertFalse(EmailAddressFormat.looksValid(text), text)
        }
    }
}
