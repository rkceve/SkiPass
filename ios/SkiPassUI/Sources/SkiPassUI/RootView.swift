import SwiftUI

enum AppTab: Hashable {
    case home
    case plan
}

/// Entry point for the host app: two native tabs, Home (accounts) and Plan.
/// On iOS 26 the system renders the tab bar as Liquid Glass; nothing is hand-drawn.
public struct RootView: View {
    @State private var store: SkiPassUIStore
    @State private var selectedTab: AppTab

    private let accounts: [MailAccount]
    private let plans: [PlanOption]
    private let usage: UsageInfo?
    private let plansAvailable: Bool
    private let autoFillEnabled: Bool

    /// - Parameters:
    ///   - plansAvailable: false when the build has no billing (no RevenueCat key).
    ///   - autoFillEnabled: false while the SkiPass AutoFill extension is turned off; Home then
    ///     shows the "Turn on AutoFill" card. Pass true while the state is still unknown.
    ///   - onTurnOnAutoFill: shows the system prompt to turn on the extension; returns whether
    ///     it is on afterwards. False makes the controls offer `onOpenAutoFillSettings` too.
    ///   - onOpenAutoFillSettings: opens the AutoFill provider settings.
    public init(
        accounts: [MailAccount],
        plans: [PlanOption],
        usage: UsageInfo?,
        plansAvailable: Bool = true,
        autoFillEnabled: Bool = true,
        onTurnOnAutoFill: @escaping @MainActor () async -> Bool = { true },
        onOpenAutoFillSettings: @escaping @MainActor () async -> Void = {},
        actions: SkiPassUIActions
    ) {
        self.accounts = accounts
        self.plans = plans
        self.usage = usage
        self.plansAvailable = plansAvailable
        self.autoFillEnabled = autoFillEnabled
        // One-time seed of view-owned state; later input changes are pushed
        // into the store by the `.onChange` handlers in `body`.
        self.store = SkiPassUIStore(
            accounts: accounts, plans: plans, usage: usage, plansAvailable: plansAvailable, actions: actions,
            autoFillEnabled: autoFillEnabled, onTurnOnAutoFill: onTurnOnAutoFill,
            onOpenAutoFillSettings: onOpenAutoFillSettings)
        self.selectedTab = .home
    }

    /// Preview / test entry point with a pre-built store.
    init(store: SkiPassUIStore, initialTab: AppTab = .home) {
        self.accounts = store.accounts
        self.plans = store.plans
        self.usage = store.usage
        self.plansAvailable = store.plansAvailable
        self.autoFillEnabled = store.autoFillEnabled
        self.store = store
        self.selectedTab = initialTab
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab(Copy.tabHome, systemImage: "house.fill", value: AppTab.home) {
                AccountsScreen(store: store)
            }
            Tab(Copy.tabPlan, systemImage: "crown.fill", value: AppTab.plan) {
                PlanScreen(store: store)
            }
        }
        .tint(Theme.accent)
        .onChange(of: accounts) { store.accounts = accounts }
        .onChange(of: plans) { store.plans = plans }
        .onChange(of: usage) { store.usage = usage }
        .onChange(of: plansAvailable) { store.plansAvailable = plansAvailable }
        .onChange(of: autoFillEnabled) { store.autoFillEnabled = autoFillEnabled }
    }
}

#Preview("Root – Home") {
    RootView(store: PreviewData.makeStore())
}

#Preview("Root – Plan") {
    RootView(store: PreviewData.makeStore(), initialTab: .plan)
}
