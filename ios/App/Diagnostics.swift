import Foundation
import SkiPassModels
import SkiPassStorage
import SkiPassUI

/// The app's side of the on-device diagnostics (SkiPassModels `DiagnosticsStore` in the shared
/// defaults): it records the groups it resolved, which the AutoFill extension compares with its own,
/// and turns the stored records into the Diagnostics card of "How SkiPass works".
@MainActor
enum LiveDiagnostics {
    static func store() -> DiagnosticsStore {
        DiagnosticsStore(defaults: SharedStorageEnvironment.current.defaults)
    }

    /// Writes the App Group / keychain group this app process resolved (once per launch).
    static func recordAppStorage(bundle: Bundle = .main) {
        let environment = SharedStorageEnvironment.current
        store().setAppStorage(StorageSnapshot(bundleID: bundle.bundleIdentifier, appGroup: environment.appGroupID,
                                              keychainGroup: environment.keychainAccessGroup, recordedAt: Date()))
    }

    /// The current records, read again each time the sheet opens. When the extension resolved no
    /// App Group, it wrote its traces to its private defaults and none show up here.
    static func load(bundle: Bundle = .main) -> DiagnosticsInfo {
        let environment = SharedStorageEnvironment.current
        let store = store()
        return DiagnosticsFormatting.info(
            bundleID: bundle.bundleIdentifier,
            appGroup: environment.appGroupID,
            keychainGroup: environment.keychainAccessGroup,
            appRegistration: store.registration(process: "app"),
            extensionRegistration: store.registration(process: "extension"),
            traces: store.traces()
        )
    }
}

/// Pure mapping from the stored records to the UI model (unit-tested).
enum DiagnosticsFormatting {
    static func info(bundleID: String?, appGroup: String?, keychainGroup: String?,
                     appRegistration: RegistrationRecord?, extensionRegistration: RegistrationRecord?,
                     traces: [AutoFillTrace]) -> DiagnosticsInfo {
        DiagnosticsInfo(
            bundleID: bundleID,
            appGroup: appGroup,
            keychainGroup: keychainGroup,
            appRegistration: appRegistration.map(registrationText),
            extensionRegistration: extensionRegistration.map(registrationText),
            requests: traces.map(request)
        )
    }

    static func registrationText(_ record: RegistrationRecord) -> String {
        "\(record.summary) (\(record.at.formatted(date: .abbreviated, time: .standard)))"
    }

    static func request(_ trace: AutoFillTrace) -> DiagnosticsInfo.Request {
        DiagnosticsInfo.Request(
            id: trace.id.uuidString,
            date: trace.startedAt,
            title: "\(trace.entryPoint) · \(trace.service ?? "no site")",
            isFilled: trace.outcome == "filled",
            lines: trace.summaryLines
        )
    }
}
