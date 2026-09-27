// CI probe app (not shipped). Driven by tools/probe/UITests/ProbeAutoFillTests.swift.
import AuthenticationServices
import SwiftUI

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var storeState = "unknown"
    @State private var enableResult = "not requested"
    @State private var registerResult = "not registered"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SkiPass probe").font(.title2.bold())
            Text("store: \(storeState)").accessibilityIdentifier("probe.storeState")
            Text("enable: \(enableResult)").accessibilityIdentifier("probe.enableResult")
            Text("register: \(registerResult)").accessibilityIdentifier("probe.registerResult")
            Button("Enable extension") { requestEnable() }
                .accessibilityIdentifier("probe.enable")
            Button("Register identity") { register() }
                .accessibilityIdentifier("probe.register")
            Button("Refresh state") { refreshState() }
                .accessibilityIdentifier("probe.refresh")
            Spacer()
        }
        .padding()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshState() }
        }
        .onAppear { refreshState() }
    }

    private func refreshState() {
        ASCredentialIdentityStore.shared.getState { state in
            let text = state.isEnabled ? "enabled" : "disabled"
            Task { @MainActor in storeState = text }
        }
    }

    private func requestEnable() {
        enableResult = "requested"
        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { enabled in
            Task { @MainActor in
                enableResult = enabled ? "true" : "false"
                refreshState()
            }
        }
    }

    private func register() {
        registerResult = "registering"
        ProbeIdentity.register { status in
            Task { @MainActor in registerResult = status }
        }
    }
}
