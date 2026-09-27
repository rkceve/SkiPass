// UI tour for the screen recording in .github/workflows/tour.yml (not a functional test suite).
// Walks every built screen of the SkiPass app at a watchable pace using the in-memory
// fixtures behind the DEBUG-only `-SkiPassTourFixtures` launch argument (ios/App/TourFixtures.swift).
//
// Runs only when the test runner has SKIPASS_TOUR=1 (xcodebuild strips the TEST_RUNNER_ prefix,
// so the workflow sets TEST_RUNNER_SKIPASS_TOUR=1). The SkiPass app must already be installed
// on the simulator: this bundle's target application is SkiPassProbe.
import XCTest

@MainActor
final class UITourTests: XCTestCase {
    /// Pause between steps so motion is visible in the recording.
    private let pace: TimeInterval = 1.2
    private var step = 0

    private enum Direction { case up, down }

    func testTour() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKIPASS_TOUR"] == "1",
            "UI tour runs only from the tour workflow (TEST_RUNNER_SKIPASS_TOUR=1)"
        )
        continueAfterFailure = false

        let app = XCUIApplication(bundleIdentifier: "io.github.rkceve.skipass")
        app.launchArguments = ["-SkiPassTourFixtures"]
        app.launch()

        // Home list.
        let addButton = app.buttons["accounts.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 30), "Home screen did not appear")
        pause("home")

        // Expand info@myshop.jp and show the server rows.
        let info = "info@myshop.jp"
        let infoExpand = app.buttons["account.\(info).expand"]
        XCTAssertTrue(infoExpand.waitForExistence(timeout: 10))
        infoExpand.tap()
        let reveal = app.buttons["account.\(info).password.reveal"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 10), "server rows did not appear")
        pause("info-expanded")

        // Reveal the password.
        reveal.tap()
        pause("password-revealed")

        // Collapse.
        infoExpand.tap()
        XCTAssertTrue(reveal.waitForNonExistence(timeout: 10))
        pause("info-collapsed")

        // Add: the sheet morphs out of the glass Add button.
        addButton.tap()
        let email = app.textFields["accountForm.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10), "add sheet did not appear")
        pause("add-sheet")

        let newAddress = "hello@studio.co"
        email.tap()
        email.typeText(newAddress)
        XCTAssertEqual(email.value as? String, newAddress)
        pause("email-typed")

        tapWhenEnabled(app.buttons["accountForm.continue"])

        // IMAP form.
        let host = app.textFields["accountForm.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "IMAP form did not appear")
        pause("imap-form")

        host.tap()
        host.typeText("mail.studio.co")
        XCTAssertEqual(host.value as? String, "mail.studio.co")

        // Port (default 993) and username (the typed address) are prefilled by the form.
        replaceText(in: app.textFields["accountForm.port"], with: "993")
        replaceText(in: app.textFields["accountForm.username"], with: newAddress)

        let password = app.secureTextFields["accountForm.password"]
        password.tap()
        password.typeText("tour-pass-123")
        pause("imap-filled")

        // Save: the new card appears.
        tapWhenEnabled(app.buttons["accountForm.save"])
        XCTAssertTrue(host.waitForNonExistence(timeout: 10), "sheet did not close")
        dismissSavePasswordPrompt(app)
        let newExpand = app.buttons["account.\(newAddress).expand"]
        XCTAssertTrue(newExpand.waitForExistence(timeout: 10), "new account card did not appear")
        pause("new-card")

        // Expand it.
        scrollToHittable(newExpand, in: app, direction: .up)
        tapOnScreen(newExpand, in: app)
        let delete = app.buttons["account.\(newAddress).delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        scrollToHittable(delete, in: app, direction: .up)
        pause("new-card-expanded")

        // Delete and confirm.
        tapOnScreen(delete, in: app)
        let confirm = confirmDeleteButton(in: app, excluding: "account.\(newAddress).delete")
        pause("delete-confirm")
        confirm.tap()
        XCTAssertTrue(newExpand.waitForNonExistence(timeout: 10), "card was not deleted")
        pause("deleted")

        // Plan tab.
        tabButton(in: app, label: "Plan").tap()
        let pro = app.buttons["plan.pro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 10), "Plan screen did not appear")
        scrollToHittable(pro, in: app, direction: .up)
        pause("plan")

        tapOnScreen(pro, in: app)
        pause("pro-tapped")

        // Back to Home.
        tabButton(in: app, label: "Home").tap()
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        pause("home-again")
    }

    // MARK: Helpers

    /// Waits `pace`, then attaches a screenshot named after the step.
    private func pause(_ name: String) {
        Thread.sleep(forTimeInterval: pace)
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapWhenEnabled(_ button: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "\(button) missing")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: button)
        wait(for: [enabled], timeout: timeout)
        button.tap()
    }

    /// Leaves the field alone when it already holds `text`; otherwise focuses it with the
    /// cursor at the end (fields are right-aligned, so a center tap lands at the start),
    /// deletes the current value and types `text`. Asserts the final value either way.
    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(field) missing")
        let current = field.value as? String ?? ""
        if current != text {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            field.typeText(deletes + text)
        }
        XCTAssertEqual(field.value as? String, text)
    }

    /// Swipes the screen's scroll view until `element` is hittable, rechecking after each swipe
    /// (bounded). Fails with the element's frame when it never becomes hittable.
    private func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, direction: Direction, attempts: Int = 4) {
        // The scroll view that contains the element (both tabs keep a scroll view alive).
        let scrollView = app.scrollViews
            .containing(NSPredicate(format: "identifier == %@", element.identifier))
            .firstMatch
        for _ in 0..<attempts {
            if element.isHittable { return }
            switch direction {
            case .up: scrollView.swipeUp(velocity: .slow)
            case .down: scrollView.swipeDown(velocity: .slow)
            }
            Thread.sleep(forTimeInterval: 0.6)  // let deceleration finish before rechecking
        }
        // After the IMAP sheet closes, iOS 26.2 sometimes keeps reporting an element that is
        // fully on screen as not hittable (seen on main 0a104dd and wip/i11 cf31d30: the new card
        // at y 476 pt, visible in the screenshot). Accept a fully visible frame; `tapOnScreen`
        // then taps its center by coordinate.
        if element.isHittable || isFullyOnScreen(element, in: app) { return }
        XCTFail("\(element.identifier) not hittable after \(attempts) swipes; frame \(element.frame)")
    }

    private func isFullyOnScreen(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        return element.exists && !frame.isEmpty && app.windows.firstMatch.frame.contains(frame)
    }

    /// Taps the element, by coordinate when XCUITest reports it not hittable although it is visible.
    private func tapOnScreen(_ element: XCUIElement, in app: XCUIApplication) {
        if element.isHittable {
            element.tap()
        } else {
            XCTAssertTrue(isFullyOnScreen(element, in: app), "\(element.identifier) is off screen; frame \(element.frame)")
            // Diagnostics: what covers the element (app hierarchy and SpringBoard overlays).
            print("TOUR-DIAG not hittable: \(element.identifier)\n\(app.debugDescription)")
            print("TOUR-DIAG springboard:\n\(XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)")
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// The dialog's destructive "Delete" action. iOS 26 renders it as a button nested in a
    /// button, so the label query has several matches: take the deepest (last in document
    /// order) hittable one that is not the card's own Delete button.
    private func confirmDeleteButton(in app: XCUIApplication, excluding cardDeleteID: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@ AND identifier != %@", "Delete", cardDeleteID)
        let query = app.buttons.matching(predicate)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let button = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                return button
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("delete confirmation did not appear; matches: \(query.allElementsBoundByIndex.map(\.debugDescription))")
        return query.element(boundBy: 0)
    }

    /// iOS may offer "Save Password?" (Passwords app) after the username/password form closes;
    /// it does not always appear. Dismiss it with "Not Now" when it does.
    private func dismissSavePasswordPrompt(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            for candidate in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where candidate.exists {
                pause("save-password-prompt")
                candidate.tap()
                XCTAssertTrue(candidate.waitForNonExistence(timeout: 5), "Save Password prompt did not close")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func tabButton(in app: XCUIApplication, label: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[label]
        if inTabBar.waitForExistence(timeout: 3) { return inTabBar }
        return app.buttons[label].firstMatch
    }
}
