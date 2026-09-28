import SkiPassUI
import SwiftUI

@main
struct SkiPassApp: App {
    @State private var model = AppModel(services: LiveServices.make())
    @State private var autoFill = AutoFillSetupModel(services: LiveAutoFillSettings())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if TourFixtures.isEnabled {
                TourRootView()
            } else {
                liveRoot
            }
            #else
            liveRoot
            #endif
        }
    }

    private var liveRoot: some View {
        RootView(
            accounts: model.accounts,
            plans: model.plans,
            usage: model.usage,
            plansAvailable: model.plansAvailable,
            autoFillEnabled: autoFill.isEnabledForUI,
            onTurnOnAutoFill: { await autoFill.requestTurnOn() },
            onOpenAutoFillSettings: { await autoFill.openSettings() },
            actions: model
        )
        .task {
            autoFill.onTurnedOn = { [model] in await model.autoFillDidTurnOn() }
            await autoFill.refresh()
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await autoFill.refresh()
                await model.didBecomeActive()
            }
        }
    }
}

#if DEBUG
/// UI tour only (`-SkiPassTourFixtures`): the same RootView fed by in-memory fixtures.
private struct TourRootView: View {
    @State private var fixtures = TourFixtureModel()

    var body: some View {
        RootView(
            accounts: fixtures.accounts,
            plans: fixtures.plans,
            usage: fixtures.usage,
            autoFillEnabled: fixtures.autoFillEnabled,
            onTurnOnAutoFill: { fixtures.turnOnAutoFill() },
            onOpenAutoFillSettings: {},
            actions: fixtures
        )
    }
}
#endif
