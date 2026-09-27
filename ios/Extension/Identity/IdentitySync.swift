import Foundation
import SkiPassModels

/// Runs identity registrations one at a time and coalesces requests (A2-13).
///
/// `replaceCredentialIdentities` rewrites the whole store, so two overlapping registrations built
/// from different snapshots could finish in the wrong order and drop a newly seen domain. Here a
/// request made while a registration runs is served by one more registration after it, which reads
/// the state at that time; any number of such requests share that single follow-up run.
actor IdentitySyncCoordinator {
    typealias Operation = @Sendable () async -> Void

    private let operation: Operation
    private var running = false
    private var waitingForNextRun: [CheckedContinuation<Void, Never>] = []

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    /// Returns after a registration that started after this call has finished.
    func sync() async {
        if running {
            await withCheckedContinuation { waitingForNextRun.append($0) }
            return
        }
        running = true
        await operation()
        while !waitingForNextRun.isEmpty {
            let served = waitingForNextRun
            waitingForNextRun = []
            await operation()
            served.forEach { $0.resume() }
        }
        running = false
    }
}

/// What the extension may register, given what it can read (A2-12).
enum IdentitySyncInput: Equatable {
    /// Register identities for these mailbox addresses (empty = remove all: there is no mailbox).
    case register([String])
    /// Leave the store as it is: the mailbox list could not be read, so "no mailboxes" is unknown.
    case keepExisting(reason: String)

    /// `appGroupResolved == false` means this process sees only its private defaults, where the app's
    /// mailboxes never are; wiping the app's identities from there would make suggestions flicker.
    static func decide(appGroupResolved: Bool, list: () throws -> [MailboxConfig]) -> IdentitySyncInput {
        guard appGroupResolved else {
            return .keepExisting(reason: "no App Group in this process")
        }
        do {
            return .register(try list().map(\.address))
        } catch {
            return .keepExisting(reason: "mailbox list unreadable: \(type(of: error))")
        }
    }
}
