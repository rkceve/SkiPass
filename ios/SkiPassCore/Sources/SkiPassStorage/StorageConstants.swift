import Foundation

/// Identifiers fixed by docs/ARCHITECTURE.md §1 and §5.
///
/// `appGroupID` and `keychainAccessGroup` are the canonical names of a normally signed build. A
/// re-signed (sideloaded) build gets different ones, so storage uses the identifiers resolved at
/// runtime by `SharedStorageEnvironment.current`; the canonical names are among its candidates.
public enum StorageConstants {
    /// Canonical App Group shared by the app and the AutoFill extension.
    public static let appGroupID = "group.io.github.rkceve.skipass"
    /// Canonical Keychain access group: same string as the App Group (docs/ARCHITECTURE.md §1).
    public static let keychainAccessGroup = appGroupID
    /// Keychain generic-password service (docs/ARCHITECTURE.md §5).
    public static let keychainService = "io.github.rkceve.skipass"

    /// UserDefaults keys (docs/ARCHITECTURE.md §5).
    public enum DefaultsKey {
        public static let mailboxes = "mailboxes.v1"
        public static let rcAppUserID = "rc.appUserID"
        public static let usageSnapshot = "usage.snapshot.v1"
    }

    /// Keychain account names (docs/ARCHITECTURE.md §5).
    public enum KeychainAccount {
        public static func password(_ mailboxID: UUID) -> String { "password.\(mailboxID.uuidString)" }
        public static func oauth(_ mailboxID: UUID) -> String { "oauth.\(mailboxID.uuidString)" }
    }

    /// The shared App Group defaults of the runtime-resolved group. Nil when no App Group container
    /// is available to this process.
    public static func sharedDefaults() -> UserDefaults? {
        SharedStorageEnvironment.current.sharedDefaults
    }
}

public enum StorageError: Error, Equatable, Sendable {
    /// The App Group container is not available (missing entitlement).
    case appGroupUnavailable
    case mailboxAlreadyExists(UUID)
    case mailboxNotFound(UUID)
    /// A Keychain call returned a non-success OSStatus.
    case keychain(status: Int32)
    /// Stored bytes could not be decoded as UTF-8.
    case invalidPasswordEncoding
}
