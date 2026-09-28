import Foundation
import SkiPassModels
@testable import SkiPassServerClient
import XCTest

/// Response bodies are the exact JSON the server returns in `server/test/api.spec.ts`.
final class ServerClientTests: XCTestCase {
    private let baseURL = URL(string: "https://skipass-server.example.workers.dev")!
    private let user = "$RCAnonymousID:0123456789abcdef"

    // Same message as `acmeMsg` in server/test/api.spec.ts.
    private let acme = FetchedMessage(
        id: "6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127",
        mailboxAddress: "user@example.com",
        from: "Acme <no-reply@acme.co.uk>",
        to: "user@example.com",
        subject: "Your Acme verification code",
        date: ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!,
        bodyText: "Your Acme verification code is 482913. It expires in 10 minutes."
    )
    private let globex = FetchedMessage(
        id: "6F9619FF-8B86-D011-B42D-00CF4FC964FF:4128",
        mailboxAddress: "user@example.com",
        from: "Globex <security@globex.com>",
        to: "user@example.com",
        subject: "Sign-in code",
        date: ISO8601DateFormatter().date(from: "2026-09-23T10:01:00Z")!,
        bodyText: "Use 771204 to sign in to Globex."
    )

    private func makeClient(user: String? = nil) -> ServerClient {
        let id = user ?? self.user
        return ServerClient(
            configuration: .init(baseURL: baseURL, appToken: "test-app-token", appUserID: { id }),
            session: StubURLProtocol.session()
        )
    }

    private func jsonObject(_ data: Data?) throws -> NSDictionary {
        let obj = try JSONSerialization.jsonObject(with: XCTUnwrap(data))
        return try XCTUnwrap(obj as? NSDictionary)
    }

    // MARK: judge

    func testJudgeSendsContractRequest() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127":0.9,"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4128":0.1},"remaining":10,"source":"jev"}
        """)
        _ = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme, globex])

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.absoluteString, "https://skipass-server.example.workers.dev/v1/judge")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-SkiPass-App-Token"), "test-app-token")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-SkiPass-User"), user)
        let expected: NSDictionary = [
            "service": "login.acme.co.uk",
            "messages": [
                ["id": acme.id, "text": acme.judgeText],
                ["id": globex.id, "text": globex.judgeText],
            ],
        ]
        XCTAssertEqual(try jsonObject(sent.body), expected)
        // Same text layout as the server fixtures (judgeText in server/test/fixtures.ts).
        XCTAssertEqual(acme.judgeText, """
        From: Acme <no-reply@acme.co.uk>
        To: user@example.com
        Subject: Your Acme verification code
        Date: 2026-09-23T10:00:00Z

        Your Acme verification code is 482913. It expires in 10 minutes.
        """)
    }

    func testJudgeSendsNullService() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"chosenId":null,"scores":{},"remaining":10,"source":"fallback"}"#)
        _ = try await makeClient().judge(service: nil, messages: [acme])
        let body = try jsonObject(StubURLProtocol.requests.first?.body)
        XCTAssertTrue(body["service"] is NSNull)
    }

    func testJudgeChosen() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127":0.9,"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4128":0.1},"remaining":10,"source":"jev"}
        """)
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme, globex])
        XCTAssertEqual(outcome, .chosen(messageID: acme.id, scores: [acme.id: 0.9, globex.id: 0.1]))
    }

    func testJudgeNoMatch() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":null,"scores":{"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127":0.49,"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4128":0.1},"remaining":10,"source":"jev"}
        """)
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme, globex])
        XCTAssertEqual(outcome, .noMatch(scores: [acme.id: 0.49, globex.id: 0.1]))
    }

    func testJudgeFallbackWithEmptyScores() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{},"remaining":10,"source":"fallback"}
        """)
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme, globex])
        XCTAssertEqual(outcome, .chosen(messageID: acme.id, scores: [:]))
    }

    func testJudgeQuotaExhausted() async throws {
        StubURLProtocol.respond(status: 402, json: #"{"error":"quota_exhausted","remaining":0}"#)
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme])
        XCTAssertEqual(outcome, .quotaExhausted)
    }

    func testJudgeWithoutMessagesMakesNoRequest() async throws {
        StubURLProtocol.respond(status: 500, json: "{}")
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [])
        XCTAssertEqual(outcome, .noMatch(scores: [:]))
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testJudgeUnauthorized() async throws {
        StubURLProtocol.respond(status: 401, json: #"{"error":"unauthorized"}"#)
        await assertThrows(ServerClientError.unauthorized) {
            _ = try await self.makeClient().judge(service: nil, messages: [self.acme])
        }
    }

    func testJudgeInvalidRequest() async throws {
        StubURLProtocol.respond(status: 400, json: #"{"error":"invalid_request"}"#)
        await assertThrows(ServerClientError.httpStatus(400)) {
            _ = try await self.makeClient().judge(service: nil, messages: [self.acme])
        }
    }

    // MARK: judge reply validation

    func testJudgeAcceptsMockSource() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127":0.9},"remaining":10,"source":"mock"}
        """)
        let outcome = try await makeClient().judge(service: "login.acme.co.uk", messages: [acme, globex])
        XCTAssertEqual(outcome, .chosen(messageID: acme.id, scores: [acme.id: 0.9]))
    }

    func testJudgeRejectsUnknownSource() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{},"remaining":10,"source":"cache"}
        """)
        await assertThrows(ServerClientError.invalidResponse) {
            _ = try await self.makeClient().judge(service: "login.acme.co.uk", messages: [self.acme])
        }
    }

    func testJudgeRejectsChosenIDThatWasNotSent() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:9999","scores":{},"remaining":10,"source":"jev"}
        """)
        await assertThrows(ServerClientError.invalidResponse) {
            _ = try await self.makeClient().judge(service: "login.acme.co.uk", messages: [self.acme, self.globex])
        }
    }

    func testJudgeRejects402WithoutQuotaBody() async throws {
        StubURLProtocol.respond(status: 402, json: "<html>Payment Required</html>")
        await assertThrows(ServerClientError.invalidResponse) {
            _ = try await self.makeClient().judge(service: "login.acme.co.uk", messages: [self.acme])
        }
    }

    func testJudgeRateLimitedThrowsSoTheCallerFallsBack() async throws {
        StubURLProtocol.respond(status: 429, json: #"{"error":"rate_limited"}"#)
        // Any thrown error makes FallbackJudge use the local rule.
        await assertThrows(ServerClientError.rateLimited) {
            _ = try await self.makeClient().judge(service: "login.acme.co.uk", messages: [self.acme])
        }
        XCTAssertTrue(ServerClientError.rateLimited.isTransient)
        XCTAssertFalse(ServerClientError.quotaExhausted.isTransient)
        XCTAssertFalse(ServerClientError.httpStatus(404).isTransient)
        XCTAssertTrue(ServerClientError.httpStatus(503).isTransient)
    }

    /// docs/API.md: a user RevenueCat does not know gets 401 unknown_user on every route.
    /// It is not retried; the extension treats it like an unavailable server (local fallback).
    func testUnknownUserIsDistinctAndNotTransient() async throws {
        StubURLProtocol.respond(status: 401, json: #"{"error":"unknown_user"}"#)
        await assertThrows(ServerClientError.unknownUser) {
            _ = try await self.makeClient(user: "local:0F2E").judge(service: nil, messages: [self.acme])
        }
        await assertThrows(ServerClientError.unknownUser) {
            _ = try await self.makeClient(user: "local:0F2E").reportFill(messageID: self.acme.id)
        }
        XCTAssertFalse(ServerClientError.unknownUser.isTransient)
    }

    /// docs/API.md: `remaining: 0` in a 200 means "not known" while RevenueCat is down,
    /// not "exhausted"; only 402 is quota exhaustion.
    func testRemainingZeroInA200IsNotQuotaExhaustion() async throws {
        StubURLProtocol.respond(status: 200, json: """
        {"chosenId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF:4127","scores":{},"remaining":0,"source":"jev"}
        """)
        let outcome = try await makeClient().judge(service: nil, messages: [acme])
        XCTAssertEqual(outcome, .chosen(messageID: acme.id, scores: [:]))

        StubURLProtocol.respond(status: 200, json: #"{"remaining":0}"#)
        let remaining = try await makeClient().reportFill(messageID: acme.id)
        XCTAssertEqual(remaining, 0)

        StubURLProtocol.respond(status: 200, json: #"{"plan":"unknown","used":3,"limit":0,"resetsAt":"2026-10-01T00:00:00Z"}"#)
        let usage = try await makeClient().currentUsage()
        XCTAssertEqual(usage.plan, "unknown")
        XCTAssertEqual(usage.limit, 0)
    }

    /// Without an app user ID the extension still asks the server to judge.
    func testJudgeWithoutAppUserIDUsesTheAnonymousJudgeUser() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"chosenId":null,"scores":{},"remaining":10,"source":"jev"}"#)
        let client = ServerClient(
            configuration: .init(baseURL: baseURL, appToken: "test-app-token", appUserID: { nil },
                                 anonymousJudgeUserID: "anonymous"),
            session: StubURLProtocol.session()
        )
        _ = try await client.judge(service: nil, messages: [acme])
        XCTAssertEqual(StubURLProtocol.requests.first?.request.value(forHTTPHeaderField: "X-SkiPass-User"), "anonymous")
    }

    func testFillsAndUsageNeverUseTheAnonymousJudgeUser() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"remaining":9}"#)
        let client = ServerClient(
            configuration: .init(baseURL: baseURL, appToken: "test-app-token", appUserID: { nil },
                                 anonymousJudgeUserID: "anonymous"),
            session: StubURLProtocol.session()
        )
        await assertThrows(ServerClientError.missingAppUserID) {
            _ = try await client.reportFill(messageID: self.acme.id)
        }
        await assertThrows(ServerClientError.missingAppUserID) {
            _ = try await client.currentUsage()
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// The configured timeout bounds the whole request, not only idle time.
    func testJudgeTimeoutBoundsTheWholeRequest() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"chosenId":null,"scores":{},"remaining":1,"source":"jev"}"#,
                                delay: 10)
        let id = user
        let client = ServerClient(
            configuration: .init(baseURL: baseURL, appToken: "test-app-token", appUserID: { id }, timeout: 0.3),
            session: StubURLProtocol.session()
        )
        let start = Date()
        do {
            _ = try await client.judge(service: nil, messages: [acme])
            XCTFail("expected a timeout")
        } catch {}
        // Only has to separate "gave up at the 0.3 s timeout" from "waited for the 10 s reply", with
        // room for slow CI simulators.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMissingAppUserIDMakesNoRequest() async throws {
        StubURLProtocol.respond(status: 200, json: "{}")
        await assertThrows(ServerClientError.missingAppUserID) {
            _ = try await self.makeClient(user: "").currentUsage()
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: fills

    func testReportFill() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"remaining":9}"#)
        let remaining = try await makeClient().reportFill(messageID: acme.id)
        XCTAssertEqual(remaining, 9)
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.url?.path, "/v1/fills")
        XCTAssertEqual(try jsonObject(sent.body), ["messageId": acme.id] as NSDictionary)
    }

    func testReportFillQuotaExhaustedThrows() async throws {
        StubURLProtocol.respond(status: 402, json: #"{"error":"quota_exhausted","remaining":0}"#)
        await assertThrows(ServerClientError.quotaExhausted) {
            try await self.makeClient().reportFill(messageID: self.acme.id)
        }
    }

    // MARK: usage

    func testCurrentUsage() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"plan":"free","used":0,"limit":10,"resetsAt":"2026-10-01T00:00:00Z"}"#)
        let usage = try await makeClient().currentUsage()
        XCTAssertEqual(usage, UsageSnapshot(plan: "free", used: 0, limit: 10,
                                            resetsAt: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!))
        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.httpMethod, "GET")
        XCTAssertEqual(sent.request.url?.path, "/v1/usage")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-SkiPass-User"), user)
    }

    func testCurrentUsageMalformedBody() async throws {
        StubURLProtocol.respond(status: 200, json: #"{"plan":"free"}"#)
        await assertThrows(ServerClientError.invalidResponse) {
            _ = try await self.makeClient().currentUsage()
        }
    }

    // MARK: helpers

    private func assertThrows(_ expected: ServerClientError,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ServerClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
