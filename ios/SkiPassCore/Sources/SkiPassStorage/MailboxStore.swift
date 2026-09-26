import Foundation
import SkiPassModels

/// Persists `[MailboxConfig]` as JSON under `mailboxes.v1` in the App Group defaults (CONTRACTS §4).
/// Holds no secrets; credentials live in `CredentialStore`.
public final class MailboxStore: @unchecked Sendable {
    // UserDefaults is thread-safe; the lock only serializes read-modify-write sequences.
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Store backed by the runtime-resolved App Group defaults, or `UserDefaults.standard` (logged by
    /// `SharedStorageEnvironment`) when no App Group is available, so the app keeps working alone.
    /// Still `throws` for source compatibility; it no longer throws.
    public convenience init() throws {
        self.init(defaults: SharedStorageEnvironment.current.defaults)
    }

    public func list() throws -> [MailboxConfig] {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    public func add(_ mailbox: MailboxConfig) throws {
        try mutate { mailboxes in
            guard !mailboxes.contains(where: { $0.id == mailbox.id }) else {
                throw StorageError.mailboxAlreadyExists(mailbox.id)
            }
            mailboxes.append(mailbox)
        }
    }

    public func update(_ mailbox: MailboxConfig) throws {
        try mutate { mailboxes in
            guard let index = mailboxes.firstIndex(where: { $0.id == mailbox.id }) else {
                throw StorageError.mailboxNotFound(mailbox.id)
            }
            mailboxes[index] = mailbox
        }
    }

    /// Removes the mailbox config. Credentials are not touched; call `CredentialStore.removeAll(for:)`.
    public func remove(id: UUID) throws {
        try mutate { mailboxes in
            guard let index = mailboxes.firstIndex(where: { $0.id == id }) else {
                throw StorageError.mailboxNotFound(id)
            }
            mailboxes.remove(at: index)
        }
    }

    private func mutate(_ body: (inout [MailboxConfig]) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var mailboxes = try load()
        try body(&mailboxes)
        defaults.set(try JSONEncoder().encode(mailboxes), forKey: StorageConstants.DefaultsKey.mailboxes)
    }

    private func load() throws -> [MailboxConfig] {
        guard let data = defaults.data(forKey: StorageConstants.DefaultsKey.mailboxes) else { return [] }
        return try JSONDecoder().decode([MailboxConfig].self, from: data)
    }
}
