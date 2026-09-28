import Foundation

/// How a mailbox signs in. Google and Microsoft use the provider's official
/// sign-in screen; everything else is a plain IMAP account.
public enum AccountKind: Hashable, Sendable {
    case google
    case microsoft
    case imap
}

/// Only the connected state exists: nothing in the app detects a mailbox that needs signing in
/// again (the extension skips failing mailboxes without recording it).
public enum ConnectionStatus: Hashable, Sendable {
    case connected
}

/// Incoming (IMAP) server settings of an IMAP account (docs/ARCHITECTURE.md §2: host, port, username).
public struct ServerSettings: Hashable, Sendable {
    public var incomingHost: String
    public var incomingPort: Int
    public var username: String

    public init(incomingHost: String, incomingPort: Int, username: String) {
        self.incomingHost = incomingHost
        self.incomingPort = incomingPort
        self.username = username
    }
}

public struct MailAccount: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var address: String
    public var kind: AccountKind
    public var status: ConnectionStatus
    /// nil for google / microsoft.
    public var server: ServerSettings?

    public init(
        id: UUID = UUID(),
        address: String,
        kind: AccountKind,
        status: ConnectionStatus,
        server: ServerSettings? = nil
    ) {
        self.id = id
        self.address = address
        self.kind = kind
        self.status = status
        self.server = server
    }
}

public struct PlanOption: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var tagline: String
    public var priceText: String
    public var isCurrent: Bool
    public var systemImage: String

    public init(
        id: String,
        name: String,
        tagline: String,
        priceText: String,
        isCurrent: Bool,
        systemImage: String
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.priceText = priceText
        self.isCurrent = isCurrent
        self.systemImage = systemImage
    }
}

public struct UsageInfo: Hashable, Sendable {
    public var used: Int
    public var limit: Int
    public var resetsAt: Date

    public init(used: Int, limit: Int, resetsAt: Date) {
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
    }

    /// Remaining count, never negative.
    var remaining: Int { max(limit - used, 0) }

    /// Remaining fraction in 0...1 (0 when limit is 0).
    var remainingFraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(Double(remaining) / Double(limit), 0), 1)
    }
}

/// Errors the host app throws to the UI. The UI shows a message from `Copy` for each case
/// (never a raw `localizedDescription`); a thrown `CancellationError` shows nothing.
public enum SkiPassUIError: Error, Hashable, Sendable {
    /// Thrown by `SkiPassUIActions.addAccount(email:)` when the address is not a
    /// Google / Microsoft account and IMAP server settings are required.
    case needsServerSettings
    /// This build has no OAuth client ID for Google.
    case googleSignInNotConfigured
    /// This build has no OAuth client ID for Microsoft.
    case microsoftSignInNotConfigured
    /// The provider sign-in failed (other than the user cancelling it).
    case signInFailed
    /// The account could not be saved (storage / Keychain error).
    case saveFailed
    /// The account could not be deleted (storage / Keychain error).
    case deleteFailed
}

extension PlanOption {
    /// The Free plan row (server plan id "free").
    public static func free(isCurrent: Bool) -> PlanOption {
        PlanOption(
            id: "free",
            name: Copy.freePlanName,
            tagline: Copy.freePlanTagline,
            priceText: Copy.freePlanPrice,
            isCurrent: isCurrent,
            systemImage: "person.fill"
        )
    }

    /// Display name of a paid server plan id ("standard" / "pro"); nil for anything else.
    public static func paidPlanName(planID: String) -> String? {
        switch planID {
        case "standard": Copy.standardPlanName
        case "pro": Copy.proPlanName
        default: nil
        }
    }

    /// Tagline of a paid server plan id ("standard" / "pro"); nil for anything else.
    /// Shown instead of the store's product description, so every build shows the same copy.
    public static func paidPlanTagline(planID: String) -> String? {
        switch planID {
        case "standard": Copy.standardPlanTagline
        case "pro": Copy.proPlanTagline
        default: nil
        }
    }
}
