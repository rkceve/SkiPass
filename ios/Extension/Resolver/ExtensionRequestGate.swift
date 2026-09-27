import Foundation

/// Guarantees exactly one terminal call (complete or cancel) per credential request (TRIAGE D11,
/// SYSTEM §3). Every entry point of the view controller goes through one gate:
///
/// - `begin()` starts a request. A request still in flight is superseded: its work is cancelled and
///   it can no longer reach the extension context, so only the newest request finishes it.
/// - `finish(_:_:)` runs the terminal action only for the current, unfinished request, once.
/// - The work task holds the controller strongly, so a request always ends in `finish` even if the
///   system releases the controller while the work is suspended.
@MainActor
final class ExtensionRequestGate {
    struct Ticket: Equatable, Sendable {
        fileprivate let generation: Int
    }

    private var generation = 0
    private var finished = true
    private var work: Task<Void, Never>?

    /// True while a request has started and not finished.
    var isPending: Bool { !finished }

    /// Starts a new request, superseding any request still in flight.
    func begin() -> Ticket {
        work?.cancel()
        work = nil
        generation += 1
        finished = false
        return Ticket(generation: generation)
    }

    /// Runs `terminal` if `ticket` is the current request and it has not finished yet.
    /// Returns whether it ran.
    @discardableResult
    func finish(_ ticket: Ticket, _ terminal: () -> Void) -> Bool {
        guard ticket.generation == generation, !finished else { return false }
        finished = true
        work = nil
        terminal()
        return true
    }

    /// Starts a request whose outcome needs asynchronous work: `resolve` runs, then exactly one of
    /// `complete` (non-nil result) or `cancel` (nil) runs, unless a newer request superseded this one.
    func run<Value: Sendable>(resolve: @escaping @Sendable () async -> Value?,
                              complete: @escaping @MainActor (Value) -> Void,
                              cancel: @escaping @MainActor () -> Void) {
        let ticket = begin()
        let task = Task { @MainActor in
            let value = await resolve()
            self.finish(ticket) {
                if let value { complete(value) } else { cancel() }
            }
        }
        if ticket.generation == generation, !finished {
            work = task
        }
    }

    /// Finishes the request right away with `terminal` (paths that cancel without any work).
    func finishNow(_ terminal: () -> Void) {
        finish(begin(), terminal)
    }
}
