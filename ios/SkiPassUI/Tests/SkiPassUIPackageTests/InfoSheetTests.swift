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

    func testSectionsAreSetupChoicePrivacyPlansVersion() {
        XCTAssertEqual(InfoSection.allCases.map(\.rawValue), ["setup", "choice", "privacy", "plans", "version"])
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
