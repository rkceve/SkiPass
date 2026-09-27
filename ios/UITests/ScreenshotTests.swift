// Store screenshots for .github/workflows/screenshots.yml (not a functional test suite).
// Uses the DEBUG-only `-SkiPassTourFixtures` in-memory data (ios/App/TourFixtures.swift): fictional
// `.example` addresses, no accounts, keychain or network.
//
// Runs only when the test runner has SKIPASS_SCREENSHOTS=1 (the workflow sets
// TEST_RUNNER_SKIPASS_SCREENSHOTS=1). At each screen (`01-home`, `02-imap-expanded`, `03-plan`)
// the test writes `<name>.ready` into SKIPASS_SHOT_DIR and waits for `<name>.done`: the workflow
// takes the image with `simctl io screenshot`, which keeps the native 1179x2556 pixels
// (XCUIScreen rounds the 393 pt width to 1178 px). An XCUIScreen attachment is kept for diagnosis.
import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    /// Lets animations (card expansion, tab switch, Liquid Glass) settle before a capture.
    private let settle: TimeInterval = 1.5

    func testScreenshots() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SKIPASS_SCREENSHOTS"] == "1",
            "Screenshots run only from the screenshots workflow (TEST_RUNNER_SKIPASS_SCREENSHOTS=1)"
        )
        continueAfterFailure = false

        let app = XCUIApplication(bundleIdentifier: "io.github.rkceve.skipass")
        app.launchArguments = ["-SkiPassTourFixtures"]
        app.launch()

        // 1. Home: the accounts list.
        let addButton = app.buttons["accounts.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 30), "Home screen did not appear")
        let info = "info@myshop.example"
        let infoExpand = app.buttons["account.\(info).expand"]
        XCTAssertTrue(infoExpand.waitForExistence(timeout: 10), "fixture account missing")
        capture("01-home")

        // 2. An expanded IMAP card (server rows, masked password).
        infoExpand.tap()
        XCTAssertTrue(app.buttons["account.\(info).password.reveal"].waitForExistence(timeout: 10),
                      "server rows did not appear")
        capture("02-imap-expanded")

        // 3. Plan tab.
        let planTab = app.tabBars.buttons["Plan"].waitForExistence(timeout: 3)
            ? app.tabBars.buttons["Plan"] : app.buttons["Plan"].firstMatch
        planTab.tap()
        XCTAssertTrue(app.buttons["plan.pro"].waitForExistence(timeout: 10), "Plan screen did not appear")
        capture("03-plan")
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: settle)
        if let dir = ProcessInfo.processInfo.environment["SKIPASS_SHOT_DIR"], !dir.isEmpty {
            requestHostScreenshot(name, in: URL(fileURLWithPath: dir))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Signals the workflow to take a simulator screenshot and waits until it is done.
    private func requestHostScreenshot(_ name: String, in dir: URL) {
        let ready = dir.appendingPathComponent("\(name).ready")
        let done = dir.appendingPathComponent("\(name).done")
        XCTAssertTrue(FileManager.default.createFile(atPath: ready.path, contents: Data()),
                      "cannot write \(ready.path)")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: done.path) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("host screenshot \(name) was not taken within 30 s")
    }
}
