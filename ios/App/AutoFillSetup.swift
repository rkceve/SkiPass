import Foundation
import Observation
import os

/// The system calls behind the "Turn on AutoFill" guidance (AuthenticationServices). The live
/// implementation is `LiveAutoFillSettings` in LiveServices.swift; tests use a fake.
@MainActor
protocol AutoFillSettingsServices: AnyObject {
    /// `ASCredentialIdentityStore.shared.state().isEnabled`: whether the SkiPass credential
    /// provider extension is turned on.
    func isExtensionEnabled() async -> Bool
    /// `ASSettingsHelper.requestToTurnOnCredentialProviderExtension()` (iOS 18): shows the system
    /// prompt "Turn on AutoFill from SkiPass?" when the extension is off. Returns whether it is on.
    func requestToTurnOnExtension() async -> Bool
    /// `ASSettingsHelper.openCredentialProviderAppSettings()`: opens Settings at the AutoFill
    /// provider settings.
    func openCredentialProviderSettings() async throws
}

/// Whether the AutoFill extension is on, and the two ways to turn it on. Feeds
/// `RootView(autoFillEnabled:onTurnOnAutoFill:onOpenAutoFillSettings:)`.
@MainActor
@Observable
final class AutoFillSetupModel {
    /// Apple: "You need to wait 10 seconds in order to make additional request to this API"
    /// (`requestToTurnOnCredentialProviderExtension(completionHandler:)`).
    static let requestInterval: TimeInterval = 10

    /// nil until the first check.
    private(set) var isEnabled: Bool?

    /// What the UI gets: an unknown state counts as on, so the card never flashes at launch.
    var isEnabledForUI: Bool { isEnabled ?? true }

    /// Runs when the extension changes from off to on (identities can now be registered).
    @ObservationIgnored var onTurnedOn: (@MainActor () async -> Void)?

    @ObservationIgnored private let services: any AutoFillSettingsServices
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastRequestAt: Date?
    @ObservationIgnored private var isRequesting = false
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "AutoFillSetup")

    init(services: any AutoFillSettingsServices, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
    }

    /// Re-reads the state. Call at launch and whenever the app becomes active (the user may
    /// have turned SkiPass on or off in Settings meanwhile).
    func refresh() async {
        await apply(await services.isExtensionEnabled())
    }

    /// Shows the system prompt. Returns whether AutoFill is on afterwards; false (declined, the
    /// prompt could not be shown, or a request less than 10 s after the previous one, which is
    /// not sent) makes the UI offer `openSettings()` as well.
    func requestTurnOn() async -> Bool {
        if isEnabled == true { return true }
        guard !isRequesting else { return false }
        if let lastRequestAt, now().timeIntervalSince(lastRequestAt) < Self.requestInterval {
            logger.notice("Turn-on request skipped: less than 10 s since the previous one")
            return false
        }
        isRequesting = true
        lastRequestAt = now()
        let enabled = await services.requestToTurnOnExtension()
        // The wait counts from the answer too: the prompt may stay open for a while.
        lastRequestAt = now()
        isRequesting = false
        await apply(enabled)
        return enabled
    }

    func openSettings() async {
        do {
            try await services.openCredentialProviderSettings()
        } catch {
            logger.error("Opening AutoFill settings failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func apply(_ enabled: Bool) async {
        let previous = isEnabled
        isEnabled = enabled
        if enabled, previous == false {
            await onTurnedOn?()
        }
    }
}
