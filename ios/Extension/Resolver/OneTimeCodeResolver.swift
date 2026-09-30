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

/// How a failed fill report is retried (up to 3 attempts, in the background).
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

/// When mail is read again because the first read found no code (the email may still be on its way:
/// a site's "sent" is not the mailbox's "delivered").
public struct FetchRetry: Sendable {
    /// Pause before the second read.
    public var delay: Duration
    /// Latest end of all mail reading, counted from the start of the request: the second read gets
    /// what is left of it (at most the per-mailbox budget). The judge (server timeout 7 s) comes on
    /// top, so a request stays within about 20 s.
    public var mailDeadline: Duration
    /// The second read is left out when less than this is left for it.
    public var minimumBudget: Duration

    public init(delay: Duration = .milliseconds(2_500), mailDeadline: Duration = .seconds(13),
                minimumBudget: Duration = .seconds(2)) {
        self.delay = delay
        self.mailDeadline = mailDeadline
        self.minimumBudget = minimumBudget
    }

    /// No second read.
    public static let never = FetchRetry(delay: .zero, mailDeadline: .zero, minimumBudget: .seconds(1))

    /// Budget of the second read after `elapsed` of the request, or nil when it would be shorter
    /// than `minimumBudget`.
    public func secondBudget(elapsed: Duration, perMailboxBudget: Duration) -> Duration? {
        let left = mailDeadline - elapsed - delay
        let budget = min(perMailboxBudget, left)
        return budget >= minimumBudget ? budget : nil
    }
}

/// Where the resolver reports its trace (docs/ARCHITECTURE.md §3, diagnostics).
public struct ResolverDiagnostics: Sendable {
    /// One line per stage (live: `os_log`).
    public var log: @Sendable (String) -> Void
    /// Fills in what only the live process knows (its App Group / keychain group) at the start.
    public var prepare: @Sendable (inout AutoFillTrace) -> Void
    /// Receives the finished trace (live: the shared defaults).
    public var finish: @Sendable (AutoFillTrace) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in },
                prepare: @escaping @Sendable (inout AutoFillTrace) -> Void = { _ in },
                finish: @escaping @Sendable (AutoFillTrace) -> Void = { _ in }) {
        self.log = log
        self.prepare = prepare
        self.finish = finish
    }
}

/// UI-free orchestration of the extension flow (docs/ARCHITECTURE.md §3, steps 2–4).
///
/// Depends only on the `SkiPassModels` protocols so it can be unit-tested with fakes.
/// Every failure resolves to `nil`; the caller cancels silently (decided: no UI). Every request
/// leaves a trace (`ResolverDiagnostics`) that says which stage ended it.
public struct OneTimeCodeResolver: Sendable {
    public typealias MailboxSource = @Sendable () async throws -> [MailboxConfig]

    /// Messages older than this are ignored (docs/ARCHITECTURE.md §3: last 10 minutes).
    public static let lookback: TimeInterval = 10 * 60
    /// Per-mailbox fetch budget (docs/ARCHITECTURE.md §3: 8 s): token refresh, TLS, login and both
    /// folders on a phone network.
    public static let defaultPerMailboxBudget: Duration = .seconds(8)
    /// The fetcher is asked to stop this long before the per-mailbox budget, so it hands over what it
    /// has read instead of being cut off with nothing.
    public static let fetchMargin: Duration = .milliseconds(400)

    private let mailboxes: MailboxSource
    private let fetcher: any MailFetching
    private let extractor: any CodeExtracting
    private let judge: any CandidateJudging
    private let usage: any UsageReporting
    private let perMailboxBudget: Duration
    private let retry: FetchRetry
    private let now: @Sendable () -> Date
    private let fillReportRetry: FillReportRetry
    private let chosenObserver: (@Sendable (FetchedMessage) -> Void)?
    private let diagnostics: ResolverDiagnostics?

    /// `chosenObserver` receives the message whose code is returned (only that one, so
    /// promotions and other sites' mail never register identities); the extension records the
    /// domains it mentions for identity registration.
    public init(mailboxes: @escaping MailboxSource,
                fetcher: any MailFetching,
                extractor: any CodeExtracting,
                judge: any CandidateJudging,
                usage: any UsageReporting,
                perMailboxBudget: Duration = OneTimeCodeResolver.defaultPerMailboxBudget,
                retry: FetchRetry = FetchRetry(),
                now: @escaping @Sendable () -> Date = { Date() },
                fillReportRetry: FillReportRetry = FillReportRetry(),
                chosenObserver: (@Sendable (FetchedMessage) -> Void)? = nil,
                diagnostics: ResolverDiagnostics? = nil) {
        self.mailboxes = mailboxes
        self.fetcher = fetcher
        self.extractor = extractor
        self.judge = judge
        self.usage = usage
        self.perMailboxBudget = perMailboxBudget
        self.retry = retry
        self.now = now
        self.fillReportRetry = fillReportRetry
        self.chosenObserver = chosenObserver
        self.diagnostics = diagnostics
    }

    /// Where stage lines go (nowhere without diagnostics).
    private var logLine: @Sendable (String) -> Void {
        if let diagnostics { return diagnostics.log }
        return { (_: String) in }
    }

    /// Finds the code for `service` (nil = no service identifier available).
    /// Returns nil on no match, quota exhaustion, or any error. `entryPoint` names the system call
    /// that started the request, for the trace.
    public func resolve(service: String?, entryPoint: String = "unspecified") async -> ResolvedCode? {
        var initial = AutoFillTrace(startedAt: now(), entryPoint: entryPoint, service: service)
        diagnostics?.prepare(&initial)
        let recorder = AutoFillTraceRecorder(trace: initial, log: logLine)
        recorder.log("request \(entryPoint) service=\(service ?? "none")")
        if let storage = initial.storage {
            let match = initial.groupsMatchApp.map { $0 ? "same as app" : "DIFFERENT from app" } ?? "app record not visible"
            recorder.log("groups appGroup=\(storage.appGroup ?? "none") keychain=\(storage.keychainGroup ?? "default") (\(match))")
        }
        let result = await AutoFillTraceRecorder.$current.withValue(recorder) {
            await resolveTraced(service: service, recorder: recorder)
        }
        let outcome = result.code == nil ? "cancelled" : "filled"
        let totalMs = recorder.elapsedMs
        recorder.update { trace in
            trace.outcome = outcome
            trace.reason = result.reason
            trace.totalMs = totalMs
        }
        let because = result.reason.map { " (" + $0 + ")" } ?? ""
        recorder.log("outcome \(outcome)\(because) after \(totalMs) ms")
        diagnostics?.finish(recorder.snapshot)
        return result.code
    }

    private func resolveTraced(service: String?, recorder: AutoFillTraceRecorder) async -> (code: ResolvedCode?, reason: String?) {
        let boxes: [MailboxConfig]
        do {
            boxes = try await mailboxes()
        } catch {
            let summary = Diagnostics.errorSummary(error)
            recorder.update { $0.mailboxError = summary }
            recorder.log("mailbox list unreadable: \(summary)")
            return (nil, "mailbox list unreadable")
        }
        recorder.update { $0.mailboxCount = boxes.count }
        recorder.log("mailboxes \(boxes.count)")
        guard !boxes.isEmpty else { return (nil, "no mailboxes visible to the extension") }

        let start = ContinuousClock.now
        let since = now().addingTimeInterval(-Self.lookback)
        var candidates = await readCandidates(in: boxes, since: since, budget: perMailboxBudget, round: 1, recorder: recorder)
        if candidates.isEmpty {
            // The email may still be in transit: wait once and read again, within the mail deadline.
            let elapsed = ContinuousClock.now - start
            if let budget = retry.secondBudget(elapsed: elapsed, perMailboxBudget: perMailboxBudget) {
                recorder.log("no code yet; reading again in \(Diagnostics.milliseconds(retry.delay)) ms")
                try? await Task.sleep(for: retry.delay)
                if Task.isCancelled { return (nil, "request superseded") }
                candidates = await readCandidates(in: boxes, since: since, budget: budget, round: 2, recorder: recorder)
            } else {
                recorder.log("no code; no time left for a second read")
            }
        }
        let count = candidates.count
        recorder.update { $0.candidateCount = count }
        recorder.log("code candidates \(count)")
        guard !candidates.isEmpty else { return (nil, "no code email found") }

        let judgeStart = ContinuousClock.now
        let outcome: JudgeOutcome
        do {
            outcome = try await judge.judge(service: service, messages: candidates.map(\.message))
        } catch {
            let summary = Diagnostics.errorSummary(error)
            recordJudge(recorder, start: judgeStart) { judge in
                judge.outcome = "error"
                judge.error = summary
            }
            return (nil, "judge failed")
        }

        switch outcome {
        case .chosen(let messageID, _):
            guard let chosen = candidates.first(where: { $0.message.id == messageID }) else {
                recordJudge(recorder, start: judgeStart) { judge in
                    judge.outcome = "chosenUnknown"
                    judge.chosenID = messageID
                }
                return (nil, "judge chose an unknown message")
            }
            recordJudge(recorder, start: judgeStart) { judge in
                judge.outcome = "chosen"
                judge.chosenID = messageID
            }
            chosenObserver?(chosen.message)
            return (ResolvedCode(code: chosen.code, messageID: chosen.message.id), nil)
        case .noMatch:
            recordJudge(recorder, start: judgeStart) { $0.outcome = "noMatch" }
            return (nil, "judge found no match")
        case .quotaExhausted:
            recordJudge(recorder, start: judgeStart) { $0.outcome = "quotaExhausted" }
            return (nil, "monthly fills used up")
        }
    }

    private func recordJudge(_ recorder: AutoFillTraceRecorder, start: ContinuousClock.Instant,
                             _ body: (inout JudgeTrace) -> Void) {
        let ms = Diagnostics.milliseconds(since: start)
        recorder.update { trace in
            var judge = trace.judge ?? JudgeTrace()
            if judge.source == nil { judge.source = "judge" }
            body(&judge)
            judge.ms = ms
            trace.judge = judge
        }
        if let judge = recorder.snapshot.judge { recorder.log(judge.summary) }
    }

    /// One fetch round of every mailbox, reduced to messages with a code, newest first.
    private func readCandidates(in boxes: [MailboxConfig], since: Date, budget: Duration, round: Int,
                                recorder: AutoFillTraceRecorder) async -> [CodeCandidate] {
        recorder.update { $0.rounds = round }
        let messages = await fetchAll(boxes, since: since, budget: budget, round: round, recorder: recorder)
        return messages
            .compactMap { message in extractor.extractCode(from: message).map { CodeCandidate(message: message, code: $0) } }
            .sorted { $0.message.date > $1.message.date }
    }

    /// Counts one fill. Call only after the system accepted the code. A failed report is retried
    /// per `fillReportRetry`; the final error is ignored: the code has already been
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

    /// Fetches every mailbox in parallel; a mailbox that fails or exceeds the budget contributes
    /// nothing. The fetcher is told to stop `fetchMargin` before the budget
    /// (`MailFetchContext.deadline`) and each mailbox records its steps in a `MailboxTraceRecorder`.
    private func fetchAll(_ boxes: [MailboxConfig], since: Date, budget: Duration, round: Int,
                          recorder: AutoFillTraceRecorder) async -> [FetchedMessage] {
        let fetcher = self.fetcher
        let log = logLine
        let fetchDeadline = ContinuousClock.now + max(budget - Self.fetchMargin, budget / 2)
        let traced = await withTaskGroup(of: (MailboxTrace, [FetchedMessage]).self) { group in
            for box in boxes {
                group.addTask {
                    let mailboxRecorder = MailboxTraceRecorder(
                        trace: MailboxTrace(mailbox: Diagnostics.maskAddress(box.address), kind: box.kind.rawValue,
                                            round: round),
                        log: log)
                    let start = ContinuousClock.now
                    let result: Result<[FetchedMessage], any Error>? = await MailboxTraceRecorder.$current.withValue(mailboxRecorder) {
                        await MailFetchContext.$deadline.withValue(fetchDeadline) {
                            await withBudget(budget) { await Self.fetchResult(fetcher, box: box, since: since) }
                        }
                    }
                    let ms = Diagnostics.milliseconds(since: start)
                    let messages: [FetchedMessage]
                    switch result {
                    case .success(let list)?:
                        messages = list
                        mailboxRecorder.update { trace in
                            trace.messages = list.count
                            trace.ms = ms
                        }
                    case .failure(let error)?:
                        messages = []
                        let summary = Diagnostics.errorSummary(error)
                        mailboxRecorder.update { trace in
                            trace.messages = 0
                            trace.ms = ms
                            if trace.error == nil { trace.error = summary }
                        }
                    case nil:
                        messages = []
                        let limit = Diagnostics.milliseconds(budget)
                        mailboxRecorder.update { trace in
                            trace.ms = ms
                            trace.error = "budget of \(limit) ms exceeded"
                        }
                    }
                    let trace = mailboxRecorder.snapshot
                    mailboxRecorder.log("done: \(trace.messages ?? 0) msgs in \(ms) ms\(trace.error.map { " — \($0)" } ?? "")")
                    return (trace, messages)
                }
            }
            var all: [(MailboxTrace, [FetchedMessage])] = []
            for await entry in group { all.append(entry) }
            return all
        }
        recorder.update { $0.mailboxes.append(contentsOf: traced.map { $0.0 }) }
        return traced.flatMap { $0.1 }
    }

    /// One mailbox fetch; a thrown error becomes `.failure`, so `withBudget`'s nil means "budget over".
    private static func fetchResult(_ fetcher: any MailFetching, box: MailboxConfig,
                                    since: Date) async -> Result<[FetchedMessage], any Error> {
        do {
            return .success(try await fetcher.recentMessages(for: box, since: since))
        } catch {
            return .failure(error)
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
