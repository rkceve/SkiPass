// Compiled only by a unit-test target that defines SKIPASS_APP_TESTS; the app target
// (sources: ios/App) compiles this file to nothing.
#if SKIPASS_APP_TESTS
import Foundation
import Testing
@testable import SkiPass

// Unit tests for AutoFillSetupModel with a fake of the AuthenticationServices calls.

@MainActor
private final class FakeAutoFillSettings: AutoFillSettingsServices {
    var enabled = false
    /// What the system prompt does: true = the user turns SkiPass on.
    var promptTurnsOn = false
    var stateReads = 0
    var requests = 0
    var settingsOpened = 0
    var openError: Error?

    func isExtensionEnabled() async -> Bool {
        stateReads += 1
        return enabled
    }

    func requestToTurnOnExtension() async -> Bool {
        requests += 1
        if promptTurnsOn { enabled = true }
        return enabled
    }

    func openCredentialProviderSettings() async throws {
        settingsOpened += 1
        if let openError { throw openError }
    }
}

/// A clock the test moves by hand (not actor-isolated: read by the model's `now` closure).
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_780_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private final class TurnOnRecorder {
    var calls = 0
}

private struct Boom: Error {}

@MainActor
struct AutoFillSetupTests {
    private let settings = FakeAutoFillSettings()
    private let clock = Clock()
    private let turnedOn = TurnOnRecorder()

    private func makeModel() -> AutoFillSetupModel {
        let model = AutoFillSetupModel(services: settings, now: { [clock] in clock.now })
        model.onTurnedOn = { [turnedOn] in turnedOn.calls += 1 }
        return model
    }

    @Test func unknownStateShowsNoCard() {
        let model = makeModel()
        #expect(model.isEnabled == nil)
        #expect(model.isEnabledForUI)
    }

    @Test func refreshReadsTheStoreState() async {
        let model = makeModel()

        await model.refresh()
        #expect(model.isEnabled == false)
        #expect(!model.isEnabledForUI)

        settings.enabled = true  // turned on in Settings, then the app became active
        await model.refresh()
        #expect(model.isEnabledForUI)
        #expect(settings.stateReads == 2)
        #expect(turnedOn.calls == 1)
    }

    @Test func alreadyOnAtLaunchIsNotATurnOn() async {
        settings.enabled = true
        let model = makeModel()

        await model.refresh()

        #expect(model.isEnabledForUI)
        #expect(turnedOn.calls == 0)
    }

    @Test func acceptedPromptTurnsOn() async {
        settings.promptTurnsOn = true
        let model = makeModel()
        await model.refresh()

        let result = await model.requestTurnOn()

        #expect(result)
        #expect(model.isEnabledForUI)
        #expect(settings.requests == 1)
        #expect(turnedOn.calls == 1)
    }

    @Test func declinedPromptReportsOff() async {
        let model = makeModel()
        await model.refresh()

        let result = await model.requestTurnOn()

        #expect(!result)
        #expect(!model.isEnabledForUI)
        #expect(turnedOn.calls == 0)
    }

    /// Apple: wait 10 seconds before another request. A request within 10 s of the previous
    /// answer is not sent (the UI then offers Settings); after 10 s it is sent again.
    @Test func secondRequestWaitsTenSeconds() async {
        let model = makeModel()
        await model.refresh()
        _ = await model.requestTurnOn()
        #expect(settings.requests == 1)

        clock.advance(9.9)
        #expect(await model.requestTurnOn() == false)
        #expect(settings.requests == 1)

        clock.advance(0.1)
        settings.promptTurnsOn = true
        #expect(await model.requestTurnOn())
        #expect(settings.requests == 2)
    }

    @Test func requestWhenAlreadyOnShowsNoPrompt() async {
        settings.enabled = true
        let model = makeModel()
        await model.refresh()

        #expect(await model.requestTurnOn())
        #expect(settings.requests == 0)
    }

    @Test func openSettingsCallsTheSystemAndSurvivesErrors() async {
        let model = makeModel()

        await model.openSettings()
        settings.openError = Boom()
        await model.openSettings()

        #expect(settings.settingsOpened == 2)
    }
}
#endif
