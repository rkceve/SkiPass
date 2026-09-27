import SkiPassUI
import SwiftUI

@main
struct SkiPassApp: App {
    @State private var model = AppModel(services: LiveServices.make())
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
            actions: model
        )
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.didBecomeActive() }
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
            actions: fixtures
        )
    }
}
#endif
