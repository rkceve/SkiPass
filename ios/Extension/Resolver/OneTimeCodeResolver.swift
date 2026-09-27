import Foundation
import SkiPassModels

/// The code to hand to the system, plus the message it came from (for fill reporting).
public struct ResolvedCode: Sendable, Hashable {
    public var code: String
    public var messageID: String

    public init(code: String, messageID: String) {
        self.code = code
        self.messageID = messageID
    }
}

/// How a failed fill report is retried (TRIAGE D4: up to 3 attempts, in the background).
public struct FillReportRetry: Sendable {
    /// Total attempts, including the first.
    public var attempts: Int
    /// Pause before the 2nd, 3rd, ... attempt (the last value repeats).
    public var delays: [Duration]
    /// False for errors a retry cannot fix (e.g. quota exhausted, no app user ID).
    public var shouldRetry: @Sendable (any Error) -> Bool

    public init(attempts: Int = 3,
                delays: [Duration] = [.milliseconds(300), .milliseconds(900)],
                shouldRetry: @escaping @Sendable (any Error) -> Bool = { _ in true }) {
        self.attempts = attempts
        self.delays = delays
        self.shouldRetry = shouldRetry
    }
}

/// UI-free orchestration of the extension flow (CONTRACTS §6, steps 2–4).
///
/// Depends only on the `SkiPassModels` protocols so it can be unit-tested with fakes.
/// Every failure resolves to `nil`; the caller cancels silently (decided: no UI).
public struct OneTimeCodeResolver: Sendable {
    public typealias MailboxSource = @Sendable () async throws -> [MailboxConfig]

    /// Messages older than this are ignored (CONTRACTS §6: last 10 minutes).
    public static let lookback: TimeInterval = 10 * 60
    /// Per-mailbox fetch budget (CONTRACTS §6: 4 s).
    public static let defaultPerMailboxBudget: Duration = .seconds(4)

    private let mailboxes: MailboxSource
    private let fetcher: any MailFetching
    private let extractor: any CodeExtracting
    private let judge: any CandidateJudging
    private let usage: any UsageReporting
    private let perMailboxBudget: Duration
    private let now: @Sendable () -> Date
    private let fillReportRetry: FillReportRetry
    private let chosenObserver: (@Sendable (FetchedMessage) -> Void)?

    /// `chosenObserver` receives the message whose code is returned (only that one: A2-10, so
    /// promotions and other sites' mail never register identities); the extension records the
    /// domains it mentions for identity registration.
    public init(mailboxes: @escaping MailboxSource,
                fetcher: any MailFetching,
                extractor: any CodeExtracting,
                judge: any CandidateJudging,
                usage: any UsageReporting,
                perMailboxBudget: Duration = OneTimeCodeResolver.defaultPerMailboxBudget,
                now: @escaping @Sendable () -> Date = { Date() },
                fillReportRetry: FillReportRetry = FillReportRetry(),
                chosenObserver: (@Sendable (FetchedMessage) -> Void)? = nil) {
        self.mailboxes = mailboxes
        self.fetcher = fetcher
        self.extractor = extractor
        self.judge = judge
        self.usage = usage
        self.perMailboxBudget = perMailboxBudget
        self.now = now
        self.fillReportRetry = fillReportRetry
        self.chosenObserver = chosenObserver
    }

    /// Finds the code for `service` (nil = no service identifier available).
    /// Returns nil on no match, quota exhaustion, or any error.
    public func resolve(service: String?) async -> ResolvedCode? {
        guard let boxes = try? await mailboxes(), !boxes.isEmpty else { return nil }

        let since = now().addingTimeInterval(-Self.lookback)
        let messages = await fetchAll(boxes, since: since)

        let candidates = messages
            .compactMap { message in extractor.extractCode(from: message).map { CodeCandidate(message: message, code: $0) } }
            .sorted { $0.message.date > $1.message.date }
        guard !candidates.isEmpty else { return nil }

        let outcome: JudgeOutcome
        do {
            outcome = try await judge.judge(service: service, messages: candidates.map(\.message))
        } catch {
            return nil
        }

        switch outcome {
        case .chosen(let messageID, _):
            guard let chosen = candidates.first(where: { $0.message.id == messageID }) else { return nil }
            chosenObserver?(chosen.message)
            return ResolvedCode(code: chosen.code, messageID: chosen.message.id)
        case .noMatch, .quotaExhausted:
            return nil
        }
    }

    /// Counts one fill. Call only after the system accepted the code. A failed report is retried
    /// per `fillReportRetry` (TRIAGE D4); the final error is ignored: the code has already been
    /// filled and nothing is shown to the user. Returns the number of attempts made.
    @discardableResult
    public func reportFill(messageID: String) async -> Int {
        let policy = fillReportRetry
        var attempt = 0
        while true {
            attempt += 1
            do {
                _ = try await usage.reportFill(messageID: messageID)
                return attempt
            } catch {
                guard attempt < policy.attempts, policy.shouldRetry(error), !Task.isCancelled else { return attempt }
                if let delay = policy.delays.isEmpty ? nil : policy.delays[min(attempt - 1, policy.delays.count - 1)] {
                    try? await Task.sleep(for: delay)
                }
            }
        }
    }

    // MARK: - Private

    /// Fetches every mailbox in parallel; a mailbox that fails or exceeds the budget contributes nothing.
    private func fetchAll(_ boxes: [MailboxConfig], since: Date) async -> [FetchedMessage] {
        let fetcher = self.fetcher
        let budget = self.perMailboxBudget
        return await withTaskGroup(of: [FetchedMessage].self) { group in
            for box in boxes {
                group.addTask {
                    let result = await withBudget(budget) {
                        try await fetcher.recentMessages(for: box, since: since)
                    }
                    return result ?? []
                }
            }
            var all: [FetchedMessage] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }
}

/// Runs `operation` and returns its value, or nil if it throws or does not finish within `budget`.
///
/// The operation runs in an unstructured task so that a fetch that ignores cancellation
/// cannot hold the caller past the budget; it is cancelled when the budget expires.
func withBudget<T: Sendable>(_ budget: Duration,
                             _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = ResumeOnce(continuation)
        let work = Task {
            let value = try? await operation()
            gate.resume(returning: value)
        }
        let timer = Task {
            try? await Task.sleep(for: budget)
            guard !Task.isCancelled else { return }
            work.cancel()
            gate.resume(returning: nil)
        }
        gate.onResume { timer.cancel() }
    }
}

/// Resumes a continuation exactly once, whichever side (work or timer) finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var cleanup: (@Sendable () -> Void)?
    private var done = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Registers work to run once the continuation has been resumed (runs immediately if it already was).
    func onResume(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if done {
            lock.unlock()
            action()
            return
        }
        cleanup = action
        lock.unlock()
    }

    func resume(returning value: T) {
        lock.lock()
        guard !done, let continuation else { lock.unlock(); return }
        done = true
        self.continuation = nil
        let action = cleanup
        cleanup = nil
        lock.unlock()
        continuation.resume(returning: value)
        action?()
    }
}
