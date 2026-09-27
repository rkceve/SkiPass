import Foundation

/// Pure logic that picks the App Group and Keychain access group at runtime.
///
/// Why: a re-signed build (e.g. sideloaded with a free Apple ID) gets a different bundle ID
/// (`io.github.rkceve.skipass.<suffix>`) and therefore different App Group / keychain-group
/// identifiers than the ones fixed in docs/ARCHITECTURE.md §1. Hard-coded identifiers then fail silently
/// (`UserDefaults(suiteName:)` still returns a process-local store) or with
/// `errSecMissingEntitlement`. The live side (`SharedStorageEnvironment`) feeds this type the
/// runtime facts and availability checks; everything here is deterministic and unit-tested.
///
/// The app and the AutoFill extension run the same ordered candidate lists, so as long as both
/// hold the same entitlements they settle on the same identifiers.
///
/// Re-signing conventions this covers (AltStore source, marketplace branch 56854e6,
/// AltStore/Operations/FetchProvisioningProfilesOperation.swift): the app ID becomes
/// `<bundle ID>.<team ID>` and extensions keep their suffix after it (L180-L193), App Groups become
/// `<group>.<team ID>` (L444), and the signed entitlements are the provisioning profile's
/// (AltSign ALTSigner.mm L230), so the groups actually granted are also read from
/// `embedded.mobileprovision` and AltStore's `ALTAppGroups` Info.plist key
/// (ResignAppOperation.swift L126-L128). Sideloadly is closed source; its bundle-ID suffix matches the
/// AltStore format, the group naming is assumed to match and is covered by the profile read anyway.
public enum SharedStorageResolver {
    /// Last bundle-ID component of the AutoFill extension (`io.github.rkceve.skipass.autofill`).
    public static let extensionComponent = "autofill"

    /// The app's bundle ID as seen from either process: the extension's `autofill` component is
    /// removed wherever a re-signing tool placed it.
    /// - `io.github.rkceve.skipass.autofill` → `io.github.rkceve.skipass`
    /// - `io.github.rkceve.skipass.LCUTH33TX7.autofill` → `io.github.rkceve.skipass.LCUTH33TX7`
    /// - `io.github.rkceve.skipass.autofill.LCUTH33TX7` → `io.github.rkceve.skipass.LCUTH33TX7`
    /// - `io.github.rkceve.skipass.LCUTH33TX7` → unchanged
    public static func appBundleIdentifier(fromRuntime bundleIdentifier: String) -> String {
        var parts = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // Keep at least one component; only strip an `autofill` that is not the first component.
        if let index = parts.lastIndex(of: extensionComponent), index > 0 {
            parts.remove(at: index)
        }
        return parts.joined(separator: ".")
    }

    /// Ordered App Group candidates:
    /// 1. `group.<runtime app bundle ID>` (the group a re-signing tool derives from the new bundle ID),
    /// 2. groups declared by the installed provisioning profile / Info.plist that belong to this
    ///    app (they contain the canonical or the runtime app bundle ID),
    /// 3. the canonical `group.io.github.rkceve.skipass` (docs/ARCHITECTURE.md §1).
    /// Duplicates are removed, first occurrence wins.
    public static func appGroupCandidates(
        runtimeBundleIdentifier: String?,
        declaredGroups: [String],
        canonicalAppGroup: String = StorageConstants.appGroupID,
        canonicalAppBundleIdentifier: String = StorageConstants.keychainService
    ) -> [String] {
        var candidates: [String] = []
        let runtimeApp = runtimeBundleIdentifier.map(appBundleIdentifier(fromRuntime:))
        if let runtimeApp, !runtimeApp.isEmpty {
            candidates.append("group.\(runtimeApp)")
        }
        let relevant = declaredGroups.filter { group in
            group.hasPrefix("group.")
                && (group.contains(canonicalAppBundleIdentifier) || (runtimeApp.map { group.contains($0) } ?? false))
        }
        candidates.append(contentsOf: relevant)
        candidates.append(canonicalAppGroup)
        return deduplicated(candidates)
    }

    /// First candidate for which `isAvailable` is true (live: the App Group container exists).
    public static func pickFirst(_ candidates: [String], where isAvailable: (String) -> Bool) -> String? {
        candidates.first(where: isAvailable)
    }

    /// Team / App ID prefix of an access group such as `LCUTH33TX7.io.github.rkceve.skipass`
    /// (the default group of an app is `<prefix>.<bundle ID>`). Nil for `group.` names and
    /// for strings whose first component is not a 10-character alphanumeric prefix.
    public static func teamPrefix(ofAccessGroup accessGroup: String) -> String? {
        guard let first = accessGroup.split(separator: ".").first, first != "group" else { return nil }
        let prefix = String(first)
        guard prefix.count == 10, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return prefix
    }

    /// Ordered Keychain access-group candidates that the app and the extension can both name:
    /// 1. the resolved App Group (App Groups double as keychain access groups on iOS),
    /// 2. `<team prefix>.<runtime app bundle ID>` (the app's own default group; usable by the
    ///    extension when its keychain-access-groups entitlement covers it, e.g. `<team>.*`),
    /// 3. the canonical keychain group from docs/ARCHITECTURE.md §1.
    public static func keychainGroupCandidates(
        appGroup: String?,
        defaultAccessGroup: String?,
        runtimeBundleIdentifier: String?,
        canonicalKeychainGroup: String = StorageConstants.keychainAccessGroup
    ) -> [String] {
        var candidates: [String] = []
        if let appGroup { candidates.append(appGroup) }
        if let defaultAccessGroup, let prefix = teamPrefix(ofAccessGroup: defaultAccessGroup),
           let runtimeBundleIdentifier {
            candidates.append("\(prefix).\(appBundleIdentifier(fromRuntime: runtimeBundleIdentifier))")
        }
        candidates.append(canonicalKeychainGroup)
        return deduplicated(candidates)
    }

    /// App Group names from provisioning-profile / signing entitlements
    /// (`com.apple.security.application-groups`), ignoring anything that is not a string array.
    public static func appGroups(fromEntitlements entitlements: [String: Any]?) -> [String] {
        (entitlements?["com.apple.security.application-groups"] as? [String]) ?? []
    }

    /// Keychain access groups from provisioning-profile / signing entitlements (`keychain-access-groups`),
    /// possibly with wildcards such as `ABCDE12345.*`.
    public static func keychainAccessGroups(fromEntitlements entitlements: [String: Any]?) -> [String] {
        (entitlements?["keychain-access-groups"] as? [String]) ?? []
    }

    /// True when an entitlement list (exact names or `prefix*` wildcards) grants `group`.
    public static func entitlementList(_ granted: [String], covers group: String) -> Bool {
        granted.contains { entry in
            if entry.hasSuffix("*") {
                return group.hasPrefix(String(entry.dropLast()))
            }
            return entry == group
        }
    }

    /// The `Entitlements` dictionary of an `embedded.mobileprovision` file.
    ///
    /// The file is a CMS (PKCS #7) signed message whose payload is an XML property list; the
    /// payload is stored uncompressed, so the plist is the byte range from `<?xml` to `</plist>`.
    /// Returns nil when no plist is found or it has no `Entitlements` dictionary.
    public static func entitlements(fromEmbeddedProvisioningProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any]
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
