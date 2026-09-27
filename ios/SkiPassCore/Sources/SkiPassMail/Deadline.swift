import Foundation

public enum MailFetchError: Error, Equatable, Sendable {
    /// The caller-supplied time budget elapsed before the fetch finished.
    case timedOut
}

enum Deadline {
    /// Runs `operation` and returns its result, or throws `MailFetchError.timedOut` once `seconds`
    /// elapse — without waiting for `operation` to notice cancellation. On timeout the operation's
    /// task is cancelled and `onTimeout` runs (used to drop the IMAP connection).
    ///
    /// The same cleanup runs when the caller's task is cancelled first (it throws
    /// `CancellationError`), e.g. when the resolver's own per-mailbox budget ends before this one
    /// (A2-05): the abandoned operation must not keep its connection open.
    ///
    /// A task group is not used on purpose: a group only returns after every child finishes,
    /// and SwiftMail commands carry their own 5–60 s timeouts that ignore task cancellation.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () async -> Void = {}
    ) async throws -> T {
        let gate = ResumeGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard gate.install(continuation) else { return }
                let work = Task {
                    do {
                        gate.resume(with: .success(try await operation()))
                    } catch {
                        gate.resume(with: .failure(error))
                    }
                }
                let timer = Task {
                    let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    if Task.isCancelled { return }
                    if gate.resume(with: .failure(MailFetchError.timedOut)) {
                        work.cancel()
                        await onTimeout()
                    }
                }
                gate.onFinish { work.cancel(); timer.cancel() }
            }
        } onCancel: {
            if gate.resume(with: .failure(CancellationError())) {
                Task { await onTimeout() }
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of work / timer / cancellation comes first.
private final class ResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var finished = false
    private var cleanup: (@Sendable () -> Void)?

    /// Returns false if a result (cancellation) already arrived; the continuation is then resumed here.
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Registers work to run once a result is delivered (runs immediately if already delivered).
    func onFinish(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            body()
            return
        }
        cleanup = body
        lock.unlock()
    }

    /// Returns true if this call delivered the result.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        continuation?.resume(with: result)
        cleanup?()
        return true
    }
}
