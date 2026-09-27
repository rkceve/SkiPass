import Foundation
import Observation

/// Which account sheet is showing. Add and edit share one id so only one
/// account form can be presented at a time.
enum AccountSheet: Identifiable, Hashable {
    case add
    case edit(MailAccount)

    var id: String { "accountForm" }
}

/// UI state for the whole package. Seeded from `RootView.init` and kept in sync
/// with later parent inputs by `RootView` (see `.onChange` there).
@MainActor
@Observable
final class SkiPassUIStore {
    var accounts: [MailAccount]
    var plans: [PlanOption]
    var usage: UsageInfo?
    /// False only when the build has no billing (no RevenueCat key): the Plan tab then says
    /// "Plans are unavailable in this build." instead of listing other plans.
    var plansAvailable: Bool
    /// Bumped whenever an account's password is saved, so a revealed password is hidden again.
    private(set) var passwordRevisions: [UUID: Int] = [:]
    var expandedAccountID: UUID?
    var accountSheet: AccountSheet?
    /// "Now" used for the reset countdown; injectable so previews match the mockup.
    var referenceDate: Date

    let actions: any SkiPassUIActions

    init(
        accounts: [MailAccount],
        plans: [PlanOption],
        usage: UsageInfo?,
        plansAvailable: Bool = true,
        actions: any SkiPassUIActions,
        referenceDate: Date = .now
    ) {
        self.accounts = accounts
        self.plans = plans
        self.usage = usage
        self.plansAvailable = plansAvailable
        self.actions = actions
        self.referenceDate = referenceDate
    }

    // MARK: Accounts

    func toggleExpanded(_ id: UUID) {
        expandedAccountID = expandedAccountID == id ? nil : id
    }

    func addAccount(email: String) async throws {
        let account = try await actions.addAccount(email: email)
        upsert(account)
    }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws {
        let account = try await actions.saveIMAP(address: address, settings: settings, password: password)
        upsert(account)
        passwordRevisions[account.id, default: 0] += 1
    }

    func deleteAccount(id: UUID) async throws {
        try await actions.deleteAccount(id: id)
        accounts.removeAll { $0.id == id }
        if expandedAccountID == id { expandedAccountID = nil }
    }

    func passwordRevision(for id: UUID) -> Int {
        passwordRevisions[id] ?? 0
    }

    func revealPassword(id: UUID) async -> String? {
        await actions.revealPassword(id: id)
    }

    /// Replaces an account with the same id (or, failing that, the same address);
    /// appends otherwise.
    private func upsert(_ account: MailAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id })
            ?? accounts.firstIndex(where: { $0.address.caseInsensitiveCompare(account.address) == .orderedSame }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
    }

    // MARK: Plans

    var currentPlan: PlanOption? { plans.first(where: \.isCurrent) }
    var otherPlans: [PlanOption] { plans.filter { !$0.isCurrent } }

    func selectPlan(id: String) async {
        await actions.selectPlan(id: id)
    }
}
