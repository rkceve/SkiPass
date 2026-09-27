import SwiftUI

/// Screen 2 (Plan tab): header, current plan with usage, other plans.
/// Low-pressure by design: nothing beyond what the mockup shows.
struct PlanScreen: View {
    let store: SkiPassUIStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeaderView(store: store)

                SectionTitle(text: Copy.planTitle)

                if let current = store.currentPlan {
                    CurrentPlanCard(plan: current, usage: store.usage, referenceDate: store.referenceDate)
                }

                let others = store.otherPlans
                if !store.plansAvailable {
                    // No RevenueCat key in this build: nothing can be purchased.
                    SectionTitle(text: Copy.otherPlansTitle)
                        .padding(.top, 8)
                    Text(Copy.plansUnavailable)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("plan.unavailable")
                } else if !others.isEmpty {
                    // Billing is configured but the offering is not loaded yet (or failed):
                    // show nothing rather than a misleading message.
                    SectionTitle(text: Copy.otherPlansTitle)
                        .padding(.top, 8)
                    VStack(spacing: 16) {
                        ForEach(others) { plan in
                            PlanRow(plan: plan) {
                                Task { await store.selectPlan(id: plan.id) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .tabBarClearance()
        .background(PastelBackground())
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

#Preview("Plan") {
    PlanScreen(store: PreviewData.makeStore())
}

#Preview("Plan – no usage yet") {
    PlanScreen(store: PreviewData.makeStore(usage: nil))
}
