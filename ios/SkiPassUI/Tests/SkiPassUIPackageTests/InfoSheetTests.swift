@testable import SkiPassUI
import SwiftUI
import XCTest

@MainActor
private final class NoActions: SkiPassUIActions {
    func addAccount(email: String) async throws -> MailAccount { throw SkiPassUIError.needsServerSettings }
    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        throw SkiPassUIError.saveFailed
    }
    func deleteAccount(id: UUID) async throws {}
    func revealPassword(id: UUID) async -> String? { nil }
    func selectPlan(id: String) async {}
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
final class InfoSheetTests: XCTestCase {
    private func makeStore(autoFillEnabled: Bool) -> SkiPassUIStore {
        SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: NoActions(), autoFillEnabled: autoFillEnabled)
    }

    func testSectionsAreSetupChoicePrivacyPlansVersionDiagnostics() {
        XCTAssertEqual(InfoSection.allCases.map(\.rawValue),
                       ["setup", "choice", "privacy", "plans", "version", "diagnostics"])
        for section in InfoSection.allCases {
            XCTAssertFalse(section.title.isEmpty, section.rawValue)
            XCTAssertEqual(section.accessibilityIdentifier, "info.section.\(section.rawValue)")
        }
        for section in [InfoSection.choice, .privacy, .plans] {
            XCTAssertFalse(section.lines.isEmpty, section.rawValue)
        }
    }

    /// The sheet body renders in both AutoFill states, and at phone width it is as tall as five
    /// section cards (a single card with a few lines is far shorter than 700 pt).
    func testInfoSheetRendersItsSections() throws {
        for enabled in [false, true] {
            let height = try renderedHeight(InfoSheetContent(store: makeStore(autoFillEnabled: enabled),
                                                             versionText: "1.2.3 (45)"))
            XCTAssertGreaterThan(height, 700, "autoFillEnabled=\(enabled)")
        }
    }

    func testSetupStepShowsControlsUntilAutoFillIsOn() throws {
        let off = try renderedHeight(InfoSheetContent(store: makeStore(autoFillEnabled: false), versionText: nil))
        let on = try renderedHeight(InfoSheetContent(store: makeStore(autoFillEnabled: true), versionText: nil))
        // The "Turn On" button is taller than the one-line "AutoFill is on" label.
        XCTAssertGreaterThan(off, on)
    }

    func testCopyStatesTheTenMinuteWindowAndNamesNoMailProvider() {
        let text = ([Copy.infoSetupAddMailbox, Copy.infoSetupTurnOnAutoFill, Copy.infoSetupOpenSite,
                     Copy.infoSetupTapSuggestion, Copy.autoFillCardTitle, Copy.autoFillCardBody]
                    + Copy.infoChoiceLines + Copy.infoPrivacyLines + Copy.infoPlansLines)
            .joined(separator: "\n")
        XCTAssertTrue(Copy.infoChoiceLines.contains { $0.contains("last 10 minutes") })
        // The extension reads the junk/spam folder too (IMAPMailFetcher), so the copy must say so.
        XCTAssertTrue(Copy.infoChoiceLines.contains { $0.contains("inbox and junk/spam folder") })
        XCTAssertTrue(Copy.infoPrivacyLines.contains { $0.contains("last 10 minutes") })
        for brand in ["Gmail", "Outlook", "Google", "Microsoft", "Yahoo", "iCloud"] {
            XCTAssertFalse(text.contains(brand), brand)
        }
    }

    // MARK: Diagnostics

    private func diagnostics(requests: [DiagnosticsInfo.Request]) -> DiagnosticsInfo {
        DiagnosticsInfo(bundleID: "io.github.rkceve.skipass.LCUTH33TX7", appGroup: "group.io.github.rkceve.skipass.LCUTH33TX7",
                        keychainGroup: nil, appRegistration: "registered 142 identities", extensionRegistration: nil,
                        requests: requests)
    }

    func testDiagnosticsWithoutRequestsSaysSoExplicitly() {
        let text = diagnostics(requests: []).plainText(versionText: "0.1.9 (7)")
        XCTAssertTrue(text.hasPrefix("SkiPass diagnostics 0.1.9 (7)"), text)
        XCTAssertTrue(text.contains("No AutoFill request has reached SkiPass yet"), text)
        XCTAssertTrue(text.contains("App Group (app): group.io.github.rkceve.skipass.LCUTH33TX7"), text)
        XCTAssertTrue(text.contains("Keychain group (app): default (not shared)"), text)
        XCTAssertTrue(text.contains("Identity registration (app): registered 142 identities"), text)
        XCTAssertTrue(text.contains("Identity registration (AutoFill): not yet"), text)
    }

    func testDiagnosticsTextListsEachRequestWithItsLines() {
        let request = DiagnosticsInfo.Request(id: "1", date: Date(timeIntervalSince1970: 1_790_000_000),
                                              title: "noUI · skipass-demo.vercel.app", isFilled: false,
                                              lines: ["Result: cancelled (no code email found)", "Mailboxes: 1"])
        let text = diagnostics(requests: [request]).plainText(versionText: nil)
        XCTAssertFalse(text.contains("No AutoFill request has reached SkiPass yet"))
        XCTAssertTrue(text.contains("noUI · skipass-demo.vercel.app"), text)
        XCTAssertTrue(text.contains("  Result: cancelled (no code email found)\n  Mailboxes: 1"), text)
    }

    /// The Diagnostics card appears only when the host supplies diagnostics.
    func testDiagnosticsCardRendersOnlyWithDiagnostics() throws {
        let store = makeStore(autoFillEnabled: true)
        let without = try renderedHeight(InfoSheetContent(store: store, versionText: nil))
        let with = try renderedHeight(InfoSheetContent(store: store, versionText: nil,
                                                       diagnostics: diagnostics(requests: [])))
        XCTAssertGreaterThan(with, without + 150)
    }

    func testDiagnosticsCopyNamesNoMailProvider() {
        let text = [Copy.diagnosticsIntro, Copy.diagnosticsNoRequests, Copy.diagnosticsNoRequestsHint].joined()
        for brand in ["Gmail", "Outlook", "Google", "Microsoft"] {
            XCTAssertFalse(text.contains(brand), brand)
        }
    }

    func testAppVersionText() {
        XCTAssertEqual(AppVersion.text(info: ["CFBundleShortVersionString": "0.1.6", "CFBundleVersion": "42"]),
                       "0.1.6 (42)")
        XCTAssertEqual(AppVersion.text(info: ["CFBundleShortVersionString": "0.1.6"]), "0.1.6")
        XCTAssertNil(AppVersion.text(info: ["CFBundleVersion": "42"]))
        XCTAssertNil(AppVersion.text(info: nil))
    }

    private func renderedHeight(_ content: InfoSheetContent) throws -> CGFloat {
        let renderer = ImageRenderer(content: content.frame(width: 393))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage, "content did not render")
        return image.size.height
    }
}

@MainActor
final class AutoFillStoreTests: XCTestCase {
    func testDeclinedRequestOffersSettings() async {
        let requests = Counter()
        let store = SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: NoActions(),
                                   autoFillEnabled: false, onTurnOnAutoFill: { requests.value += 1; return false })
        XCTAssertFalse(store.autoFillSettingsOffered)

        await store.requestAutoFill()

        XCTAssertEqual(requests.value, 1)
        XCTAssertTrue(store.autoFillSettingsOffered)
        XCTAssertFalse(store.isRequestingAutoFill)
    }

    func testAcceptedRequestDoesNotOfferSettings() async {
        let store = SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: NoActions(),
                                   autoFillEnabled: false, onTurnOnAutoFill: { true })

        await store.requestAutoFill()

        XCTAssertFalse(store.autoFillSettingsOffered)
    }

    func testOpenSettingsCallsTheHost() async {
        let opened = Counter()
        let store = SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: NoActions(),
                                   onOpenAutoFillSettings: { opened.value += 1 })

        await store.openAutoFillSettings()

        XCTAssertEqual(opened.value, 1)
    }

    /// The UI does not flip `autoFillEnabled` itself; only the host's value counts.
    func testEnabledStateComesFromTheHost() async {
        let store = SkiPassUIStore(accounts: [], plans: [], usage: nil, actions: NoActions(),
                                   autoFillEnabled: false, onTurnOnAutoFill: { true })
        await store.requestAutoFill()
        XCTAssertFalse(store.autoFillEnabled)
        store.autoFillEnabled = true
        XCTAssertTrue(store.autoFillEnabled)
    }
}
