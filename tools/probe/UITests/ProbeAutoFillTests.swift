// CI experiment: can a third-party credential provider supply a one-time code to Safari
// in the iOS Simulator, and what does the QuickType suggestion look like?
// Every step attaches a screenshot (and accessibility dumps at key points) to the .xcresult.
import XCTest

@MainActor
final class ProbeAutoFillTests: XCTestCase {
    // Computed: XCUIApplication is a main-actor proxy and cheap to recreate.
    private var probe: XCUIApplication { XCUIApplication(bundleIdentifier: "io.github.rkceve.skipass.probe") }
    private var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }
    private var settings: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Preferences") }
    private var safari: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.mobilesafari") }
    private let probeURL = "https://rkceve.github.io/SkiPass/"
    private var step = 0

    func testProbeOneTimeCodeFill() throws {
        continueAfterFailure = false

        probe.launch()
        XCTAssertTrue(probe.buttons["probe.enable"].waitForExistence(timeout: 20))
        snap("probe-launched")

        // 1. Enable the credential provider extension.
        if !storeEnabled() {
            enableViaSettingsHelper()
        }
        if !storeEnabled() {
            enableViaSettingsApp()
        }
        probe.activate()
        snap("probe-after-enable")
        XCTAssertTrue(storeEnabled(), "credential provider extension could not be enabled")

        // 2. Register the one-time-code identity for the probe domain.
        probe.buttons["probe.register"].tap()
        let registered = probe.staticTexts["probe.registerResult"]
        XCTAssertTrue(waitFor(registered, label: "register: registered", timeout: 10), "register: \(registered.label)")
        snap("probe-registered")

        // 3. Open the probe page in Safari.
        XCUIDevice.shared.system.open(URL(string: probeURL + "?t=\(Int(Date().timeIntervalSince1970))")!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30))
        snap("safari-opened")
        dismissSafariOnboarding()
        let field = safari.webViews.textFields.firstMatch
        if !field.waitForExistence(timeout: 30) {
            // Page load can stall on a fresh simulator; open the URL once more.
            snap("safari-field-missing")
            dump(safari, "safari-field-missing")
            XCUIDevice.shared.system.open(URL(string: probeURL + "?retry=\(Int(Date().timeIntervalSince1970))")!)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 60), "probe page field not found")
        snap("probe-page-loaded")

        // 4. Focus the one-time-code field; the QuickType bar should appear above the keyboard.
        field.tap()
        var tries = 0
        while !safari.keyboards.firstMatch.waitForExistence(timeout: 5), tries < 2 {
            tries += 1
            snap("no-keyboard-retap-\(tries)")
            field.tap()
        }
        record("keyboard-count", "\(safari.keyboards.count)")
        sleep(3)
        snap("keyboard-suggestion-bar")
        dump(safari, "safari-with-keyboard")
        dump(springboard, "springboard-with-keyboard")

        // 5. Tap our suggestion (preferred), else the key icon -> extension OTP list.
        if let suggestion = findSuggestion() {
            record("suggestion-found", "label=\(suggestion.label) type=\(suggestion.elementType.rawValue) id=\(suggestion.identifier) frame=\(suggestion.frame)")
            suggestion.tap()
            snap("suggestion-tapped")
        } else {
            record("suggestion-found", "none")
            XCTAssertTrue(openOTPListFallback(), "no QuickType suggestion and no OTP-list fallback")
        }

        // 6. Verify the page received the code.
        let echo = safari.webViews.staticTexts["Filled: 123456"]
        let filled = echo.waitForExistence(timeout: 15)
        snap("after-fill")
        dump(safari, "safari-after-fill")
        record("field-value", String(describing: field.value))
        XCTAssertTrue(filled || (field.value as? String) == "123456", "field value: \(String(describing: field.value))")
    }

    // MARK: - Enabling

    private func storeEnabled() -> Bool {
        probe.activate()
        let refresh = probe.buttons["probe.refresh"]
        guard refresh.waitForExistence(timeout: 10) else { return false }
        refresh.tap()
        return waitFor(probe.staticTexts["probe.storeState"], label: "store: enabled", timeout: 3)
    }

    private func enableViaSettingsHelper() {
        probe.buttons["probe.enable"].tap()
        snap("helper-requested")
        let deadline = Date().addingTimeInterval(15)
        var handled = false
        while Date() < deadline, !handled {
            for (name, app) in [("springboard", springboard), ("probe", probe)] {
                let alert = app.alerts.firstMatch
                let sheet = app.sheets.firstMatch
                let container = alert.exists ? alert : (sheet.exists ? sheet : nil)
                guard let container else { continue }
                snap("helper-prompt-\(name)")
                dump(app, "helper-prompt-\(name)")
                let positive = container.buttons.matching(NSPredicate(
                    format: "label CONTAINS[c] 'Turn On' OR label CONTAINS[c] 'Allow' OR label CONTAINS[c] 'Enable' OR label CONTAINS[c] 'Continue' OR label ==[c] 'OK'"
                )).firstMatch
                let target = positive.exists ? positive : container.buttons.element(boundBy: container.buttons.count - 1)
                record("helper-prompt-button", target.label)
                target.tap()
                handled = true
                break
            }
            if !handled { usleep(500_000) }
        }
        if !handled {
            snap("helper-no-prompt")
            dump(springboard, "helper-no-prompt-springboard")
            dump(probe, "helper-no-prompt-probe")
        }
        _ = waitFor(probe.staticTexts["probe.enableResult"], labelNot: "enable: requested", timeout: 10)
        record("helper-result", probe.staticTexts["probe.enableResult"].label)
        snap("helper-done")
    }

    private func enableViaSettingsApp() {
        settings.launch()
        snap("settings-launched")
        tapScrolling(settings, "General")
        snap("settings-general")
        tapScrolling(settings, "AutoFill & Passwords")
        snap("settings-autofill")
        dump(settings, "settings-autofill")
        // The row is a Switch labelled "SkiPassProbe, Verification codes" wrapping an inner unlabelled Switch;
        // tapping the row centre does not toggle it, so tap the inner switch.
        let toggle = settings.switches.matching(NSPredicate(format: "label CONTAINS[c] 'SkiPassProbe'")).firstMatch
        if toggle.waitForExistence(timeout: 5) {
            record("settings-row", "label=\(toggle.label) value=\(String(describing: toggle.value))")
            if (toggle.value as? String) != "1" {
                let inner = toggle.switches.firstMatch
                (inner.exists ? inner : toggle).tap()
            }
        } else {
            let cell = settings.cells.matching(NSPredicate(format: "label CONTAINS[c] 'SkiPassProbe'")).firstMatch
            if cell.exists { cell.tap() }
        }
        sleep(2)
        snap("settings-toggled")
        dump(settings, "settings-toggled")
        // Some iOS versions confirm with an alert or sheet.
        for app in [settings, springboard] {
            for container in [app.alerts.firstMatch, app.sheets.firstMatch] where container.exists {
                snap("settings-confirm")
                dump(app, "settings-confirm")
                container.buttons.element(boundBy: container.buttons.count - 1).tap()
                sleep(2)
            }
        }
        record("settings-row-after", toggle.exists ? String(describing: toggle.value) : "missing")
        snap("settings-after-confirm")
    }

    // MARK: - Safari

    private func dismissSafariOnboarding() {
        for _ in 0..<4 {
            let button = safari.buttons.matching(NSPredicate(
                // Not "Close": the address bar's stop-loading button can match and cancel the page load.
                format: "label IN {'Continue', 'Not Now'}"
            )).firstMatch
            guard button.waitForExistence(timeout: 3) else { return }
            snap("safari-onboarding")
            record("safari-onboarding-button", button.label)
            button.tap()
        }
    }

    private func findSuggestion() -> XCUIElement? {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] 'probe@example.com' OR label CONTAINS[c] 'From probe' OR label CONTAINS[c] 'SkiPassProbe' OR label == '123456'"
        )
        let scopes: [(String, XCUIElementQuery)] = [
            ("safari.keyboards", safari.keyboards.descendants(matching: .any)),
            ("safari.buttons", safari.buttons),
            ("safari.any", safari.descendants(matching: .any)),
            ("springboard.any", springboard.descendants(matching: .any)),
        ]
        for (name, query) in scopes {
            let matches = query.matching(predicate)
            for index in 0..<matches.count {
                let element = matches.element(boundBy: index)
                guard element.exists, element.isHittable else { continue }
                // Ignore page content, the status-bar "Return to SkiPassProbe" breadcrumb, and anything
                // not in the lower half of the screen (where the keyboard / QuickType bar lives).
                if element.identifier == "breadcrumb" || element.label.hasPrefix("Return to") { continue }
                if element.elementType == .staticText, element.label.hasPrefix("Filled") { continue }
                if element.frame.minY < 300 { continue }
                record("suggestion-scope", name)
                return element
            }
        }
        return nil
    }

    private func openOTPListFallback() -> Bool {
        let key = safari.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'Password' OR label CONTAINS[c] 'AutoFill' OR label CONTAINS[c] 'key' OR identifier CONTAINS[c] 'key'"
        )).firstMatch
        guard key.exists else {
            snap("fallback-no-key-icon")
            return false
        }
        record("fallback-key-icon", key.label)
        key.tap()
        sleep(3)
        snap("fallback-after-key-icon")
        dump(safari, "fallback-after-key-icon-safari")
        dump(springboard, "fallback-after-key-icon-springboard")
        for app in [safari, springboard] {
            let choose = app.buttons["probe.ext.choose"]
            if choose.waitForExistence(timeout: 5) {
                choose.tap()
                snap("fallback-chosen")
                return true
            }
            let probeRow = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'SkiPassProbe'")).firstMatch
            if probeRow.exists {
                probeRow.tap()
                sleep(2)
                snap("fallback-probe-row")
                let chooseAfter = app.buttons["probe.ext.choose"]
                if chooseAfter.waitForExistence(timeout: 5) {
                    chooseAfter.tap()
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Helpers

    private func tapScrolling(_ app: XCUIApplication, _ label: String) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        if element.exists {
            element.tap()
        } else {
            record("tap-missing", label)
        }
        sleep(1)
    }

    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitFor(_ element: XCUIElement, labelNot: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != %@", labelNot), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func snap(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let text = app.state == .notRunning ? "(not running)" : app.debugDescription
        record("tree-\(name)", text)
    }

    private func record(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PROBE[\(name)]: \(text.prefix(2000))")
    }
}
