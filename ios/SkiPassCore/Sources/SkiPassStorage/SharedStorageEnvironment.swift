import Foundation
import Security
import os

/// App Group and Keychain access group actually usable by this process, resolved once at
/// runtime and verified (see `SharedStorageResolver` for why the identifiers are not fixed).
///
/// - App Group: the first candidate for which
///   `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` returns a URL
///   ("In iOS, the value is nil when the group identifier is invalid";
///   https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)).
///   `UserDefaults(suiteName:)` alone is not a check: its documentation promises no nil for a group
///   the app lacks, so an unentitled suite would silently not be shared with the extension.
/// - Keychain: the first candidate group a probe item can be written to. `SecItemAdd` "returns
///   [errSecMissingEntitlement] when you specify an access group to which your app doesn't belong"
///   (https://developer.apple.com/documentation/security/errsecmissingentitlement). App Group names
///   are valid keychain access groups ("You can use app group names as keychain access group names";
///   https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).
///   The default group is read back (`kSecReturnAttributes`,
///   https://developer.apple.com/documentation/security/ksecreturnattributes) from a probe item added
///   without `kSecAttrAccessGroup`: "keychain services defaults to the app's first access group"
///   (https://developer.apple.com/documentation/security/ksecattraccessgroup). The probe adds a
///   fresh unique item rather than querying first, because a query without a group "search[es] all
///   the app's access groups" and could return an item from another group.
///
/// Fallbacks keep the app working when nothing shared is available: `UserDefaults.standard` and
/// the process's default keychain group (no `kSecAttrAccessGroup`). The extension then sees no
/// mailboxes, which it already handles by cancelling silently. Every decision is logged.
public struct SharedStorageEnvironment: Sendable {
    /// Verified App Group, or nil when none of the candidates is available to this process.
    public let appGroupID: String?
    /// Keychain access group to write to; nil means "omit `kSecAttrAccessGroup`" (process default).
    public let keychainAccessGroup: String?
    /// The keychain group was verified writable by this process and is one the extension can also
    /// name (App Group or team-prefixed app ID). Whether the extension is entitled to it is assumed
    /// from identical entitlements, not verified from this process; both processes log the groups
    /// they resolved, and the app logs whether the embedded extension's profile grants them.
    public let keychainGroupIsShared: Bool

    public init(appGroupID: String?, keychainAccessGroup: String?, keychainGroupIsShared: Bool) {
        self.appGroupID = appGroupID
        self.keychainAccessGroup = keychainAccessGroup
        self.keychainGroupIsShared = keychainGroupIsShared
    }

    /// Resolved once per process on first use.
    public static let current: SharedStorageEnvironment = resolve(bundle: .main)

    /// Defaults shared with the other process, or nil when no App Group is available.
    public var sharedDefaults: UserDefaults? {
        appGroupID.flatMap { UserDefaults(suiteName: $0) }
    }

    /// Shared defaults when available, otherwise `UserDefaults.standard` (app keeps working alone).
    public var defaults: UserDefaults {
        sharedDefaults ?? .standard
    }

    // MARK: Live resolution

    private static let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "Storage")

    static func resolve(bundle: Bundle) -> SharedStorageEnvironment {
        let bundleID = bundle.bundleIdentifier
        let declared = declaredAppGroups(bundle: bundle)

        let groupCandidates = SharedStorageResolver.appGroupCandidates(
            runtimeBundleIdentifier: bundleID,
            declaredGroups: declared
        )
        let appGroup = SharedStorageResolver.pickFirst(groupCandidates) { group in
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil
        }
        if let appGroup {
            let bundleText = bundleID ?? "nil"
            logger.notice("App Group resolved: \(appGroup, privacy: .public) (bundle \(bundleText, privacy: .public))")
        } else {
            let tried = groupCandidates.joined(separator: ", ")
            logger.error("No App Group available (tried \(tried, privacy: .public)); using UserDefaults.standard, not shared with the AutoFill extension")
        }

        let defaultGroup = KeychainProbe.defaultAccessGroup()
        let keychainCandidates = SharedStorageResolver.keychainGroupCandidates(
            appGroup: appGroup,
            defaultAccessGroup: defaultGroup,
            runtimeBundleIdentifier: bundleID
        )
        let environment: SharedStorageEnvironment
        if let keychainGroup = SharedStorageResolver.pickFirst(keychainCandidates, where: KeychainProbe.canWrite(accessGroup:)) {
            logger.notice("Keychain access group resolved: \(keychainGroup, privacy: .public)")
            environment = SharedStorageEnvironment(appGroupID: appGroup, keychainAccessGroup: keychainGroup, keychainGroupIsShared: true)
        } else {
            let tried = keychainCandidates.joined(separator: ", ")
            let fallback = defaultGroup ?? "unknown"
            logger.error("No shared keychain access group writable (tried \(tried, privacy: .public)); using the default group \(fallback, privacy: .public), not shared with the AutoFill extension")
            environment = SharedStorageEnvironment(appGroupID: appGroup, keychainAccessGroup: nil, keychainGroupIsShared: false)
        }
        logSummary(environment, bundle: bundle, defaultGroup: defaultGroup)
        return environment
    }

    /// One line per process with everything needed to compare the app's and the extension's view
    /// from a device log (TRIAGE "Not fixed": keychain sharing cannot be verified off-device, so both
    /// processes log the groups they resolved). The app also checks the embedded extension's signed
    /// profile, when present, for the groups it chose.
    private static func logSummary(_ environment: SharedStorageEnvironment, bundle: Bundle, defaultGroup: String?) {
        let isExtension = bundle.bundleURL.pathExtension == "appex"
        let role = isExtension ? "extension" : "app"
        let bundleText = bundle.bundleIdentifier ?? "nil"
        let appGroupText = environment.appGroupID ?? "none"
        let keychainText = environment.keychainAccessGroup ?? "default(\(defaultGroup ?? "unknown"))"
        let profile = profileEntitlements(at: bundle.url(forResource: "embedded", withExtension: "mobileprovision"))
        let profileKeychain = profile.map { SharedStorageResolver.keychainAccessGroups(fromEntitlements: $0).joined(separator: ",") } ?? "no profile"
        logger.notice("Shared storage [\(role, privacy: .public)] bundle=\(bundleText, privacy: .public) appGroup=\(appGroupText, privacy: .public) keychainGroup=\(keychainText, privacy: .public) sharedAssumed=\(environment.keychainGroupIsShared, privacy: .public) profileKeychainGroups=\(profileKeychain, privacy: .public)")

        guard !isExtension, let plugIns = bundle.builtInPlugInsURL,
              let appexes = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
        else { return }
        for appex in appexes where appex.pathExtension == "appex" {
            let name = appex.lastPathComponent
            guard let entitlements = profileEntitlements(at: appex.appendingPathComponent("embedded.mobileprovision")) else {
                logger.notice("Extension \(name, privacy: .public): no embedded profile; keychain sharing not checkable from the app")
                continue
            }
            let keychainGroups = SharedStorageResolver.keychainAccessGroups(fromEntitlements: entitlements)
            let appGroups = SharedStorageResolver.appGroups(fromEntitlements: entitlements)
            let granted = keychainGroups + appGroups
            let keychainOK = environment.keychainAccessGroup.map { SharedStorageResolver.entitlementList(granted, covers: $0) } ?? false
            let appGroupOK = environment.appGroupID.map { appGroups.contains($0) } ?? false
            let summary = "Extension \(name): profile grants keychain \(keychainGroups.joined(separator: ",")) / app groups \(appGroups.joined(separator: ",")); app's keychain group covered: \(keychainOK), app's App Group covered: \(appGroupOK)"
            if keychainOK && appGroupOK {
                logger.notice("\(summary, privacy: .public)")
            } else {
                logger.error("\(summary, privacy: .public) — mailboxes or credentials will not be visible to the AutoFill extension")
            }
        }
    }

    private static func profileEntitlements(at url: URL?) -> [String: Any]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return SharedStorageResolver.entitlements(fromEmbeddedProvisioningProfile: data)
    }

    /// App Groups named by the installed provisioning profile (`embedded.mobileprovision`, present
    /// in development / ad-hoc / sideloaded installs, absent from App Store installs) and by the
    /// `ALTAppGroups` Info.plist key that AltStore/SideStore write when they re-sign.
    private static func declaredAppGroups(bundle: Bundle) -> [String] {
        var groups: [String] = []
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            groups += SharedStorageResolver.appGroups(
                fromEntitlements: SharedStorageResolver.entitlements(fromEmbeddedProvisioningProfile: data)
            )
        }
        if let altGroups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
            groups += altGroups
        }
        return groups
    }
}

/// Keychain probes with a throwaway generic-password item (never holds a secret).
enum KeychainProbe {
    private static let service = "io.github.rkceve.skipass.probe"

    private static func probeQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// The access group the system assigns when `kSecAttrAccessGroup` is omitted: add a probe item
    /// without it and read the attribute back from the returned attributes (`kSecReturnAttributes`).
    static func defaultAccessGroup() -> String? {
        let account = "default-group.\(UUID().uuidString)"
        var add = probeQuery(account: account, accessGroup: nil)
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &result)
        defer { SecItemDelete(probeQuery(account: account, accessGroup: nil) as CFDictionary) }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }

    /// True when this process may write items to `accessGroup` (probe add + delete).
    static func canWrite(accessGroup: String) -> Bool {
        let account = "group-check.\(UUID().uuidString)"
        var add = probeQuery(account: account, accessGroup: accessGroup)
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probeQuery(account: account, accessGroup: accessGroup) as CFDictionary)
        return status == errSecSuccess || status == errSecDuplicateItem
    }
}
