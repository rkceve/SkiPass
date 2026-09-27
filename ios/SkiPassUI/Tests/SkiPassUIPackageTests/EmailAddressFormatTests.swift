@testable import SkiPassUI
import XCTest

final class EmailAddressFormatTests: XCTestCase {
    func testAcceptsOrdinaryAddresses() {
        for address in ["name@example.com", "info@myshop.jp", "hello@studio.co", "a.b+tag@mail.example.co.uk",
                        "Real.Name@gmail.com", "x@y.io"] {
            XCTAssertTrue(EmailAddressFormat.looksValid(address), address)
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
