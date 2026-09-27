import Foundation
@testable import SkiPassMail
import SkiPassModels
import XCTest

private final class CallFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Waits and ignores cancellation, like a SwiftMail command waiting on its own timeout.
///
/// Suspends on a dispatch timer instead of looping over `Task.sleep`: once the task is cancelled,
/// `Task.sleep` throws at once, and such a loop would spin on a cooperative thread until the end,
/// starving the (small) simulator thread pool and slowing unrelated tests.
func uncancellableSleep(_ seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

final class DeadlineTests: XCTestCase {
    func testReturnsResultBeforeDeadline() async throws {
        let value = try await Deadline.run(seconds: 2, operation: { 42 })
        XCTAssertEqual(value, 42)
    }

    func testPropagatesOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await Deadline.run(seconds: 2, operation: { () async throws -> Int in throw Boom() })
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testTimesOutPromptlyEvenIfOperationIgnoresCancellation() async {
        let timedOut = CallFlag()
        let start = Date()
        do {
            _ = try await Deadline.run(
                seconds: 0.2,
                operation: { () async throws -> Int in
                    await uncancellableSleep(3)
                    return 1
                },
                onTimeout: { timedOut.set() }
            )
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? MailFetchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        // onTimeout runs right after the result is delivered.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(timedOut.isSet)
    }

    func testOnTimeoutNotCalledOnSuccess() async throws {
        let timedOut = CallFlag()
        _ = try await Deadline.run(seconds: 0.2, operation: { 1 }, onTimeout: { timedOut.set() })
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(timedOut.isSet)
    }

    func testOuterCancellationEndsWait() async {
        let task = Task {
            try await Deadline.run(seconds: 5, operation: { () async throws -> Int in
                await uncancellableSleep(3)
                return 1
            })
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    /// A2-05: when the caller gives up first (the resolver's own budget), the IMAP connection must
    /// still be dropped, so the cleanup that runs on timeout also runs on cancellation.
    func testOuterCancellationAlsoRunsCleanup() async {
        let cleaned = CallFlag()
        let task = Task {
            try await Deadline.run(
                seconds: 5,
                operation: { () async throws -> Int in
                    await uncancellableSleep(3)
                    return 1
                },
                onTimeout: { cleaned.set() }
            )
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        _ = await task.result
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(cleaned.isSet)
    }
}

final class IMAPMailFetcherTimeoutTests: XCTestCase {
    /// A credential source that never answers must not hold the caller past the budget.
    /// No network is touched: the fetch stalls before `connect()`.
    func testCallerTimeoutCoversCredentialLookup() async {
        let stalled = ClosureCredentialProvider { _ in
            await uncancellableSleep(3)
            return .password("unused")
        }
        let fetcher = IMAPMailFetcher(credentials: stalled, timeout: 0.3)
        let mailbox = MailboxConfig(address: "me@icloud.com", kind: .imap, imapHost: "imap.mail.me.com",
                                    imapPort: 993, username: "me")
        let start = Date()
        do {
            _ = try await fetcher.recentMessages(for: mailbox, since: Date())
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? MailFetchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testClosureCredentialProviderForwards() async throws {
        let provider = ClosureCredentialProvider { mailbox in .xoauth2(accessToken: "token-for-\(mailbox.username)") }
        let mailbox = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com",
                                    imapPort: 993, username: "a@gmail.com")
        let credential = try await provider.credential(for: mailbox)
        XCTAssertEqual(credential, .xoauth2(accessToken: "token-for-a@gmail.com"))
    }
}
