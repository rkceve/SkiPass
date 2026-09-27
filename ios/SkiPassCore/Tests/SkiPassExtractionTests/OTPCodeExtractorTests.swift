import XCTest
import SkiPassModels
import SkiPassExtraction

final class OTPCodeExtractorTests: XCTestCase {
    private let extractor = OTPCodeExtractor()

    private func message(subject: String, body: String, from: String = "Acme <no-reply@acme.example>") -> FetchedMessage {
        FetchedMessage(id: "00000000-0000-0000-0000-000000000000:1", mailboxAddress: "user@example.com",
                       from: from, to: "user@example.com", subject: subject,
                       date: Date(timeIntervalSince1970: 1_790_000_000), bodyText: body)
    }

    func testHTMLEmailFixtures() throws {
        let manifest = try JSONDecoder().decode(EmailCases.self, from: FixtureLoader.data("emails.json"))
        XCTAssertEqual(manifest.cases.count, 9)
        for testCase in manifest.cases {
            let html = try FixtureLoader.string(testCase.file)
            let body = HTMLText.plainText(fromHTML: html)
            let code = extractor.extractCode(from: message(subject: testCase.subject, body: body, from: testCase.from))
            XCTAssertEqual(code, testCase.expected, "\(testCase.name) (\(testCase.file))\n--- body ---\n\(body)")
        }
    }

    func testSubjectWinsOverBody() {
        let msg = message(subject: "482913 is your Acme code", body: "Your verification code is 111222")
        XCTAssertEqual(extractor.extractCode(from: msg), "482913")
    }

    func testBodyUsedWhenSubjectHasNoCode() {
        let msg = message(subject: "Verify your email", body: "Your verification code is 604817.\nIt expires in 10 minutes.")
        XCTAssertEqual(extractor.extractCode(from: msg), "604817")
    }

    func testCodeIsReturnedAsTyped() {
        // 2FHey drops spaces and dashes, and keeps Google's G- prefix.
        XCTAssertEqual(extractor.extractCode(from: message(subject: "Sign-in", body: "Your code: 123-456")), "123456")
        XCTAssertEqual(extractor.extractCode(from: message(subject: "Sign-in", body: "Your verification code is\n\n123 456\n")), "123456")
        XCTAssertEqual(extractor.extractCode(from: message(subject: "G-482913 is your Google verification code", body: "")), "G-482913")
    }

    func testNoCodeInPlainMail() {
        XCTAssertNil(extractor.extractCode(from: message(subject: "Lunch?", body: "Running 15 minutes late, sorry!")))
        XCTAssertNil(extractor.extractCode(from: message(subject: "", body: "")))
    }
}
