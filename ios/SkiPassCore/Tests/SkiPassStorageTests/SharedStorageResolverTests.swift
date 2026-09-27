import Foundation
@testable import SkiPassStorage
import XCTest

/// Pure resolution logic behind `SharedStorageEnvironment`. The bundle IDs mirror the real
/// sideloaded install (Sideloadly, free Apple ID): `io.github.rkceve.skipass.LCUTH33TX7`.
final class SharedStorageResolverTests: XCTestCase {
    private let sideloadedApp = "io.github.rkceve.skipass.LCUTH33TX7"

    // MARK: Bundle IDs

    func testAppBundleIdentifierStripsExtensionComponent() {
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: "io.github.rkceve.skipass"),
                       "io.github.rkceve.skipass")
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: "io.github.rkceve.skipass.autofill"),
                       "io.github.rkceve.skipass")
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: sideloadedApp), sideloadedApp)
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: "\(sideloadedApp).autofill"),
                       sideloadedApp)
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: "io.github.rkceve.skipass.autofill.LCUTH33TX7"),
                       sideloadedApp)
        XCTAssertEqual(SharedStorageResolver.appBundleIdentifier(fromRuntime: "autofill"), "autofill")
    }

    // MARK: App Group

    func testCanonicalBuildTriesCanonicalGroupOnly() {
        let candidates = SharedStorageResolver.appGroupCandidates(
            runtimeBundleIdentifier: "io.github.rkceve.skipass.autofill", declaredGroups: [])
        XCTAssertEqual(candidates, ["group.io.github.rkceve.skipass"])
    }

    func testSideloadedAppAndExtensionShareTheSameCandidateOrder() {
        let declared = ["group.io.github.rkceve.skipass.LCUTH33TX7", "group.other.app"]
        let app = SharedStorageResolver.appGroupCandidates(runtimeBundleIdentifier: sideloadedApp,
                                                           declaredGroups: declared)
        let ext = SharedStorageResolver.appGroupCandidates(runtimeBundleIdentifier: "\(sideloadedApp).autofill",
                                                           declaredGroups: declared)
        XCTAssertEqual(app, ["group.io.github.rkceve.skipass.LCUTH33TX7", "group.io.github.rkceve.skipass"])
        XCTAssertEqual(ext, app)
    }

    func testDeclaredGroupWithOtherNameIsTriedBeforeCanonical() {
        let candidates = SharedStorageResolver.appGroupCandidates(
            runtimeBundleIdentifier: sideloadedApp,
            declaredGroups: ["group.io.github.rkceve.skipass.ABCDE12345", "notagroup.io.github.rkceve.skipass"])
        XCTAssertEqual(candidates, [
            "group.io.github.rkceve.skipass.LCUTH33TX7",
            "group.io.github.rkceve.skipass.ABCDE12345",
            "group.io.github.rkceve.skipass",
        ])
    }

    func testPickFirstAvailable() {
        let candidates = ["group.a", "group.b", "group.c"]
        XCTAssertEqual(SharedStorageResolver.pickFirst(candidates) { $0 != "group.a" }, "group.b")
        XCTAssertNil(SharedStorageResolver.pickFirst(candidates) { _ in false })
    }

    // MARK: Keychain

    func testTeamPrefix() {
        XCTAssertEqual(SharedStorageResolver.teamPrefix(ofAccessGroup: "LCUTH33TX7.\(sideloadedApp)"), "LCUTH33TX7")
        XCTAssertNil(SharedStorageResolver.teamPrefix(ofAccessGroup: "group.io.github.rkceve.skipass"))
        XCTAssertNil(SharedStorageResolver.teamPrefix(ofAccessGroup: "io.github.rkceve.skipass"))
        XCTAssertNil(SharedStorageResolver.teamPrefix(ofAccessGroup: "SHORT.x"))
    }

    func testKeychainCandidatesPreferAppGroupThenTeamPrefixedAppID() {
        let candidates = SharedStorageResolver.keychainGroupCandidates(
            appGroup: "group.io.github.rkceve.skipass.LCUTH33TX7",
            defaultAccessGroup: "LCUTH33TX7.\(sideloadedApp).autofill",
            runtimeBundleIdentifier: "\(sideloadedApp).autofill")
        XCTAssertEqual(candidates, [
            "group.io.github.rkceve.skipass.LCUTH33TX7",
            "LCUTH33TX7.\(sideloadedApp)",
            "group.io.github.rkceve.skipass",
        ])
    }

    func testKeychainCandidatesWithoutAppGroupOrDefault() {
        XCTAssertEqual(
            SharedStorageResolver.keychainGroupCandidates(appGroup: nil, defaultAccessGroup: nil,
                                                          runtimeBundleIdentifier: sideloadedApp),
            ["group.io.github.rkceve.skipass"])
    }

    func testKeychainCandidatesForCanonicalBuildDeduplicate() {
        XCTAssertEqual(
            SharedStorageResolver.keychainGroupCandidates(appGroup: "group.io.github.rkceve.skipass",
                                                          defaultAccessGroup: "group.io.github.rkceve.skipass",
                                                          runtimeBundleIdentifier: "io.github.rkceve.skipass"),
            ["group.io.github.rkceve.skipass"])
    }

    // MARK: Provisioning profile

    /// An `embedded.mobileprovision` is a CMS envelope around an XML plist; the bytes around the
    /// plist stand in for the DER wrapper. Keys follow the profile format (`AppIDName`,
    /// `ApplicationIdentifierPrefix`, `Entitlements`, `TeamIdentifier`).
    private func profileData(entitlements: String) -> Data {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>AppIDName</key><string>SkiPass</string>
            \t<key>ApplicationIdentifierPrefix</key><array><string>LCUTH33TX7</string></array>
            \t<key>Entitlements</key>
            \t<dict>\(entitlements)</dict>
            \t<key>TeamIdentifier</key><array><string>LCUTH33TX7</string></array>
            </dict>
            </plist>
            """
        return Data([0x30, 0x82, 0x1F, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0x00])
    }

    func testEntitlementsFromEmbeddedProfile() {
        let data = profileData(entitlements: """
            <key>application-identifier</key><string>LCUTH33TX7.\(sideloadedApp)</string>
            <key>com.apple.security.application-groups</key>
            <array><string>group.io.github.rkceve.skipass.LCUTH33TX7</string></array>
            <key>keychain-access-groups</key><array><string>LCUTH33TX7.*</string></array>
            """)
        let entitlements = SharedStorageResolver.entitlements(fromEmbeddedProvisioningProfile: data)
        XCTAssertEqual(entitlements?["application-identifier"] as? String, "LCUTH33TX7.\(sideloadedApp)")
        XCTAssertEqual(SharedStorageResolver.appGroups(fromEntitlements: entitlements),
                       ["group.io.github.rkceve.skipass.LCUTH33TX7"])
    }

    func testProfileWithoutGroupsOrPlist() {
        let noGroups = profileData(entitlements: "<key>get-task-allow</key><true/>")
        XCTAssertEqual(SharedStorageResolver.appGroups(
            fromEntitlements: SharedStorageResolver.entitlements(fromEmbeddedProvisioningProfile: noGroups)), [])
        XCTAssertNil(SharedStorageResolver.entitlements(fromEmbeddedProvisioningProfile: Data([0x30, 0x82, 0x00])))
        XCTAssertEqual(SharedStorageResolver.appGroups(fromEntitlements: nil), [])
    }

    // MARK: Fallback

    func testEnvironmentWithoutAppGroupFallsBackToStandardDefaults() {
        let environment = SharedStorageEnvironment(appGroupID: nil, keychainAccessGroup: nil, keychainGroupIsShared: false)
        XCTAssertNil(environment.sharedDefaults)
        XCTAssertTrue(environment.defaults === UserDefaults.standard)
    }
}
