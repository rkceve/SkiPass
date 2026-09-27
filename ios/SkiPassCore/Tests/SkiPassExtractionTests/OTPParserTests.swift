import XCTest
@testable import SkiPassExtraction

/// Port-fidelity tests: every message/expected pair of 2FHey's own test file
/// (TwoFHeyTests/TwoFHeyTests.swift @ 76a3c02, CC0-1.0) through the ported parser.
final class OTPParserTests: XCTestCase {
    private func loadCases() throws -> [TwoFHeyCases.Case] {
        try JSONDecoder().decode(TwoFHeyCases.self, from: FixtureLoader.data("twofhey-cases.json")).cases
    }

    func testBundledPatternFilesLoad() {
        let config = OTPParser.shared.configuration
        // 7 language files and custom-patterns.json at 76a3c02, plus SkiPass's ja.json (1 pattern).
        XCTAssertEqual(config.customPatterns.count, 6)
        XCTAssertEqual(config.languagePatterns.count, 16 + 5 + 5 + 4 + 3 + 4 + 12 + 1)
        XCTAssertTrue(config.keywords.contains("認証コード"))
        XCTAssertTrue(config.keywords.contains("verification"))
        XCTAssertTrue(config.keywords.contains("验证码"))
    }

    func testUpstreamCasesInMessageMode() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 51)
        for testCase in cases {
            let parsed = OTPParser.shared.parse(testCase.message, sender: testCase.sender, mode: .message)
            XCTAssertEqual(parsed?.code, testCase.expected, "TwoFHeyTests.swift:L\(testCase.line)")
            if let service = testCase.service {
                XCTAssertEqual(parsed?.service, service, "TwoFHeyTests.swift:L\(testCase.line) service")
            }
        }
    }

    /// The email-subject mode only adds forbidden zones; it must not lose any upstream case.
    func testUpstreamCasesInEmailSubjectMode() throws {
        for testCase in try loadCases() {
            let parsed = OTPParser.shared.parse(testCase.message, sender: testCase.sender, mode: .emailSubject)
            XCTAssertEqual(parsed?.code, testCase.expected, "TwoFHeyTests.swift:L\(testCase.line)")
        }
    }

    func testEmailGuardRejectsLabelledNumbers() {
        let parser = OTPParser.shared
        XCTAssertNil(parser.parse("Please confirm your order number 48213977", mode: .emailSubject))
        XCTAssertNil(parser.parse("Booking confirmation no. 583920 — verify your details", mode: .emailSubject))
        XCTAssertNil(parser.parse("Security notice © 2026 Acme", mode: .emailSubject))
        // Upstream accepts the same text in message mode.
        XCTAssertEqual(parser.parse("Please confirm your order number 48213977", mode: .message)?.code, "48213977")
        // "confirmation code" is an OTP label, not a reference number.
        XCTAssertEqual(parser.parse("Your confirmation code: 583920", mode: .emailSubject)?.code, "583920")
    }

    func testEmailModesIgnoreShortKeywordsInsideWords() {
        let parser = OTPParser.shared
        let text = "Order confirmation\nWireless Mouse M185, Graphite"
        XCTAssertEqual(parser.parse(text, mode: .message)?.code, "M185") // upstream: "use M185"
        XCTAssertNil(parser.parse(text, mode: .emailBody))
        // Compound words ending in "code" still count.
        XCTAssertEqual(parser.parse("Ihr Sicherheitscode: 482913", mode: .emailBody)?.code, "482913")
    }

    func testEmailBodyFallbackNeedsCodeOnItsOwnLine() {
        let parser = OTPParser.shared
        XCTAssertNil(parser.parse("Security update\nWe shipped 4 fixes in release 2026 for you.", mode: .emailBody))
        XCTAssertEqual(parser.parse("Security update\nWe shipped 4 fixes in release 2026 for you.", mode: .message)?.code, "2026")
        XCTAssertEqual(parser.parse("Enter this to verify:\n\n  604817  \n\nThanks", mode: .emailBody)?.code, "604817")
    }
}
