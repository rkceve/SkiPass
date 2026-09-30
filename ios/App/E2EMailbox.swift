// Test hook for the end-to-end recording (.github/workflows/e2e.yml, ios/UITests/EndToEndTests.swift);
// not a feature. Compiled only into Debug builds. Launching with `-SkiPassE2EMailbox` adds one IMAP
// mailbox through the regular `AppModel.saveIMAP` path (Keychain + App Group, exactly as the form
// does), taking the address and app password from the launch environment. The password is never
// logged or shown.
#if DEBUG
import Foundation
import SkiPassUI
import os

enum E2EMailbox {
    static let launchArgument = "-SkiPassE2EMailbox"
    static let addressKey = "SKIPASS_E2E_ADDRESS"
    static let passwordKey = "SKIPASS_E2E_PASSWORD"
    static let host = "imap.gmail.com"
    static let port = 993

    private static let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "E2E")

    /// Adds the mailbox when the launch argument and both environment values are present.
    @MainActor
    static func addIfRequested(to model: AppModel, processInfo: ProcessInfo = .processInfo) async {
        guard processInfo.arguments.contains(launchArgument) else { return }
        let environment = processInfo.environment
        guard let address = environment[addressKey], !address.isEmpty,
              let password = environment[passwordKey], !password.isEmpty
        else {
            logger.error("E2E mailbox requested but the address or password is missing")
            return
        }
        do {
            _ = try await model.saveIMAP(
                address: address,
                settings: ServerSettings(incomingHost: host, incomingPort: port, username: address),
                password: password
            )
            logger.notice("E2E mailbox added")
        } catch {
            logger.error("E2E mailbox could not be added: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
#endif
