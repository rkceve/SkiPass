// End-to-end recording for .github/workflows/e2e.yml (not part of the regular test runs).
// The real flow, nothing mocked: SkiPass (Debug) adds one IMAP mailbox through its normal save path
// (DEBUG-only `-SkiPassE2EMailbox`, ios/App/E2EMailbox.swift), AutoFill is turned on, Safari opens
// the demo site, requests a code by email, and the SkiPass QuickType suggestion fills it: the
// extension reads the mailbox over IMAP and the server judges the candidates.
//
// Runs only when the test runner has SKIPASS_E2E=1, DEMO_MAILBOX_ADDRESS and DEMO_IMAP_APP_PASSWORD
// (the workflow sets them with the TEST_RUNNER_ prefix, which xcodebuild strips). The password is
// handed to the app in its launch environment only; it is never printed, attached or shown.
// Screenshots go to SKIPASS_E2E_SHOT_DIR (host path) when set; nothing is attached to the result.
import XCTest

@MainActor
final class EndToEndTests: XCTestCase {
    private let bundleID = "io.github.rkceve.skipass"
    private let demoURL = "https://skipass-demo.vercel.app/"
    private var app: XCUIApplication { XCUIApplication(bundleIdentifier: bundleID) }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var settings: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Preferences") }
    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    private var step = 0
    private var address = ""

    private struct StepFailed: Error {}

    func testCodeFromEmailFillsSafari() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SKIPASS_E2E"] == "1", "runs only from the e2e workflow (TEST_RUNNER_SKIPASS_E2E=1)")
        guard let address = environment["DEMO_MAILBOX_ADDRESS"], !address.isEmpty,
              let password = environment["DEMO_IMAP_APP_PASSWORD"], !password.isEmpty
        else {
            throw XCTSkip("demo mailbox secrets are not set")
        }
        self.address = address
        continueAfterFailure = false

        // 1. Launch SkiPass; it adds the demo mailbox through the normal IMAP save path.
        let app = self.app
        app.launchArguments = ["-SkiPassE2EMailbox"]
        app.launchEnvironment = ["SKIPASS_E2E_ADDRESS": address, "SKIPASS_E2E_PASSWORD": password]
        app.launch()
        try require(app.buttons["accounts.add"].waitForExistence(timeout: 30), "Home screen did not appear")
        try require(app.buttons["account.\(address).expand"].waitForExistence(timeout: 20), "demo mailbox card did not appear")
        pause(1.5)
        snap("app-mailbox-added")

        // 2. Turn on AutoFill (system prompt; Settings as a fallback). The app then registers identities.
        try enableAutoFill()
        pause(3)  // identity registration after the turn-on
        snap("app-autofill-on")
        showDiagnostics(name: "registration")

        // 3. Safari: request a code for the demo mailbox.
        XCUIDevice.shared.system.open(URL(string: demoURL)!)
        try require(safari.wait(for: .runningForeground, timeout: 30), "Safari did not open")
        dismissSafariOnboarding()
        let email = safari.webViews.textFields.firstMatch
        if !email.waitForExistence(timeout: 30) {
            snap("safari-field-missing")
            XCUIDevice.shared.system.open(URL(string: demoURL + "?retry=1")!)
        }
        try require(email.waitForExistence(timeout: 60), "demo page email field not found")
        pause(1)
        dismissSafariTips()
        snap("demo-page")
        try require(focus(email), "email field did not take keyboard focus")
        email.typeText(address)
        pause(1)
        snap("email-typed")
        let send = safari.webViews.buttons["Email me a code"]
        if send.exists && send.isHittable {
            send.tap()
        } else {
            email.typeText("\n")
        }
        let sentAt = Date()
        let codeField = safari.webViews.textFields.firstMatch
        try require(safari.webViews.staticTexts["Check your email"].waitForExistence(timeout: 30), "verify page did not appear")
        pause(1)
        snap("verify-page")

        // 4. Tap the code field and the SkiPass suggestion until the code is filled and verified.
        let deadline = sentAt.addingTimeInterval(150)
        var attempt = 0
        var verified = false
        pause(6)  // give the email a moment to arrive
        while Date() < deadline, !verified {
            attempt += 1
            dismissSafariTips()
            if !focus(codeField) {
                snap("code-field-no-focus-\(attempt)")
                log("attempt \(attempt): code field did not take focus")
            }
            guard let suggestion = waitForSuggestion(timeout: 8) else {
                snap("no-suggestion-\(attempt)")
                log("attempt \(attempt): no suggestion")
                dismissKeyboard()
                pause(3)
                continue
            }
            log("attempt \(attempt): suggestion '\(masked(suggestion.label))'")
            snap("suggestion-\(attempt)")
            suggestion.tap()
            verified = waitForVerified(timeout: 25)
            if !verified {
                snap("not-filled-\(attempt)")
                log("attempt \(attempt): not verified; status '\(statusText())'")
                pause(3)
            }
        }
        if verified {
            pause(3)
            snap("verified")
            log("verified after \(Int(Date().timeIntervalSince(sentAt))) s, \(attempt) attempt(s)")
        }
        try require(verified, "code was not filled and verified")
    }

    // MARK: - AutoFill

    private func enableAutoFill() throws {
        let card = app.buttons["autofill.turnOn"]
        guard card.waitForExistence(timeout: 5) else {
            log("AutoFill card absent (already on)")
            return
        }
        snap("app-autofill-card")
        card.tap()
        if tapSystemPrompt() {
            pause(1)
        } else {
            enableViaSettingsApp()
            app.activate()
        }
        if !card.waitForNonExistence(timeout: 15) {
            // The app re-reads the state when it becomes active: bring it to the foreground once more.
            app.activate()
            pause(2)
        }
        try require(card.waitForNonExistence(timeout: 10), "AutoFill could not be turned on")
    }

    /// "Turn on AutoFill from SkiPass?" (SpringBoard or in-app alert/sheet): taps Turn On.
    private func tapSystemPrompt() -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            for candidate in [springboard, app] {
                let alert = candidate.alerts.firstMatch
                let sheet = candidate.sheets.firstMatch
                let container = alert.exists ? alert : (sheet.exists ? sheet : nil)
                guard let container else { continue }
                snap("autofill-prompt")
                let positive = container.buttons.matching(NSPredicate(
                    format: "label CONTAINS[c] 'Turn On' OR label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'Enable' OR label CONTAINS[c] 'Continue' OR label ==[c] 'OK'"
                )).firstMatch
                let target = positive.exists ? positive : container.buttons.element(boundBy: container.buttons.count - 1)
                log("prompt button '\(target.label)'")
                target.tap()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        snap("autofill-no-prompt")
        return false
    }

    private func enableViaSettingsApp() {
        settings.launch()
        tapScrolling(settings, "General")
        tapScrolling(settings, "AutoFill & Passwords")
        snap("settings-autofill")
        let toggle = settings.switches.matching(NSPredicate(format: "label BEGINSWITH[c] 'SkiPass'")).firstMatch
        if toggle.waitForExistence(timeout: 5), (toggle.value as? String) != "1" {
            let inner = toggle.switches.firstMatch
            (inner.exists ? inner : toggle).tap()
        }
        Thread.sleep(forTimeInterval: 2)
        for candidate in [settings, springboard] {
            for container in [candidate.alerts.firstMatch, candidate.sheets.firstMatch] where container.exists {
                container.buttons.element(boundBy: container.buttons.count - 1).tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        snap("settings-toggled")
    }

    // MARK: - Safari

    private func dismissSafariOnboarding() {
        for _ in 0..<4 {
            let button = safari.buttons.matching(NSPredicate(format: "label IN {'Continue', 'Not Now'}")).firstMatch
            guard button.waitForExistence(timeout: 3) else { return }
            snap("safari-onboarding")
            button.tap()
        }
    }

    /// Safari's first-run tip popovers ("View Bookmarks, Share Menu, and Open Tabs") cover the page
    /// and swallow taps: close them with their X button (only in the lower part of the screen, so the
    /// address bar's stop-loading button is never hit).
    private func dismissSafariTips() {
        for _ in 0..<3 {
            let close = safari.buttons.matching(NSPredicate(format: "label ==[c] 'Close' OR label ==[c] 'Dismiss'"))
                .allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.frame.minY > 250 }
            guard let close else { return }
            snap("safari-tip")
            log("closing Safari tip")
            close.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Taps a web text field until the keyboard is up (bounded), by coordinate as a last resort.
    private func focus(_ field: XCUIElement) -> Bool {
        for attempt in 0..<4 {
            if attempt == 3 {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                field.tap()
            }
            if safari.keyboards.firstMatch.waitForExistence(timeout: 4),
               (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? true {
                return true
            }
            dismissSafariTips()
        }
        return safari.keyboards.firstMatch.exists
    }

    /// The SkiPass QuickType suggestion ("From <address>") above the keyboard.
    private func waitForSuggestion(timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "label BEGINSWITH 'From ' OR label CONTAINS[c] 'SkiPass'")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let keyboard = safari.keyboards.firstMatch
            let keyboardTop = keyboard.exists ? keyboard.frame.minY : 400
            for (_, query) in [("keyboard", safari.keyboards.descendants(matching: .any)),
                               ("safari", safari.descendants(matching: .any)),
                               ("springboard", springboard.descendants(matching: .any))] {
                let matches = query.matching(predicate)
                for index in 0..<min(matches.count, 12) {
                    let element = matches.element(boundBy: index)
                    guard element.exists, element.isHittable else { continue }
                    if element.label.hasPrefix("Return to") { continue }
                    // The QuickType bar sits at (or just above) the top of the keyboard.
                    if element.frame.maxY < keyboardTop - 80 { continue }
                    return element
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    private func waitForVerified(timeout: TimeInterval) -> Bool {
        let done = safari.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Card issued' OR label BEGINSWITH 'You’re in'")).firstMatch
        return done.waitForExistence(timeout: timeout)
    }

    private func statusText() -> String {
        let status = safari.webViews.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'code' AND (label CONTAINS 'match' OR label CONTAINS 'expired' OR label CONTAINS 'Enter' OR label CONTAINS 'waiting')"
        )).firstMatch
        return status.exists ? status.label : "-"
    }

    private func dismissKeyboard() {
        let done = safari.buttons["Done"]
        if done.exists && done.isHittable { done.tap() }
    }

    // MARK: - Diagnostics

    /// Opens "How SkiPass works" and scrolls to its Diagnostics card (screenshots only).
    private func showDiagnostics(name: String) {
        let app = self.app
        app.activate()
        let info = app.buttons["header.info"]
        guard info.waitForExistence(timeout: 10) else { return }
        info.tap()
        let done = app.buttons["info.done"]
        guard done.waitForExistence(timeout: 10) else { return }
        let section = app.descendants(matching: .any)["info.section.diagnostics"].firstMatch
        for _ in 0..<8 {
            if section.exists && section.isHittable { break }
            app.swipeUp()
        }
        pause(1)
        snap("diagnostics-\(name)-1")
        app.swipeUp()
        pause(1)
        snap("diagnostics-\(name)-2")
        done.tap()
        _ = done.waitForNonExistence(timeout: 10)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard !condition else { return }
        snap("failure")
        log("FAILED: \(message)")
        showDiagnostics(name: "failure")
        XCTFail(message)
        throw StepFailed()
    }

    // MARK: - Helpers

    private func tapScrolling(_ app: XCUIApplication, _ label: String) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        if element.exists { element.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Writes a screenshot to SKIPASS_E2E_SHOT_DIR (never attached to the result bundle).
    private func snap(_ name: String) {
        step += 1
        guard let dir = ProcessInfo.processInfo.environment["SKIPASS_E2E_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%@.png", step, name))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    /// The address is replaced before printing (logs stay free of it, secrets masking aside).
    private func masked(_ text: String) -> String {
        address.isEmpty ? text : text.replacingOccurrences(of: address, with: "<demo mailbox>")
    }

    private func log(_ text: String) {
        print("E2E[\(step)]: \(masked(text))")
    }
}
