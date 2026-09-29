// Compiled only by a unit-test target that defines SKIPASS_APP_TESTS (see AppModelTests.swift).
#if SKIPASS_APP_TESTS
import Foundation
import SkiPassModels
import SkiPassUI
import Testing
@testable import SkiPass

struct DiagnosticsFormattingTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func requestsKeepOrderOutcomeAndReadableLines() {
        var filled = AutoFillTrace(startedAt: date, entryPoint: "noUI", service: "skipass-demo.vercel.app")
        filled.outcome = "filled"
        filled.mailboxCount = 1
        var cancelled = AutoFillTrace(startedAt: date, entryPoint: "textToInsert", service: nil)
        cancelled.outcome = "cancelled"
        cancelled.reason = "no code email found"

        let info = DiagnosticsFormatting.info(bundleID: "io.github.rkceve.skipass.X", appGroup: "group.x",
                                              keychainGroup: nil, appRegistration: nil, extensionRegistration: nil,
                                              traces: [filled, cancelled])

        #expect(info.requests.map(\.title) == ["noUI · skipass-demo.vercel.app", "textToInsert · no site"])
        #expect(info.requests.map(\.isFilled) == [true, false])
        #expect(info.requests[1].lines.first == "Result: cancelled (no code email found)")
        #expect(info.appGroup == "group.x")
        #expect(info.keychainGroup == nil)
        #expect(info.appRegistration == nil)
    }

    @Test func registrationTextNamesOutcomeCountAndStore() {
        let registered = RegistrationRecord(process: "app", at: date, outcome: "registered", count: 142, storeEnabled: true)
        let disabled = RegistrationRecord(process: "extension", at: date, outcome: "storeDisabled", storeEnabled: false)

        let info = DiagnosticsFormatting.info(bundleID: nil, appGroup: nil, keychainGroup: nil,
                                              appRegistration: registered, extensionRegistration: disabled, traces: [])

        #expect(info.appRegistration?.hasPrefix("registered 142 identities") == true)
        #expect(info.extensionRegistration?.hasPrefix("storeDisabled (AutoFill off)") == true)
        #expect(info.requests.isEmpty)
    }
}
#endif
