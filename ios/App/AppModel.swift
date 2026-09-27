import Foundation
import Observation
import SkiPassModels
import SkiPassUI
import os

/// App state fed into `SkiPassUI.RootView` and the implementation of the UI's side effects.
@MainActor
@Observable
final class AppModel: SkiPassUIActions {
    private(set) var accounts: [MailAccount] = []
    private(set) var plans: [PlanOption] = []
    private(set) var usage: UsageInfo?

    @ObservationIgnored private let services: AppServicesBundle
    @ObservationIgnored private var appUserID: String?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var isRefreshingUsage = false
    /// A plan change (purchase sheet / subscription management) is in progress; further taps are ignored.
    @ObservationIgnored private var isChangingPlan = false
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "AppModel")

    init(services: AppServicesBundle) {
        self.services = services
        self.plans = Self.planOptions(packages: [], activeProductIDs: [])
    }

    // MARK: Lifecycle

    /// Loads local state, configures RevenueCat and fetches plans and usage. Runs once.
    func start() async {
        guard !didStart else { return }
        didStart = true

        reloadAccounts()
        if let cached = services.sharedState.cachedUsage() {
            usage = Self.usageInfo(from: cached)
        }

        appUserID = services.billing.configure()
        if let appUserID {
            services.sharedState.setAppUserID(appUserID)
        }

        await refreshPlans()
        await refreshUsage()
        await syncIdentities()
    }

    /// Called when the app returns to the foreground (e.g. from subscription management or from
    /// Settings after enabling AutoFill, which is when the identity store becomes writable).
    func didBecomeActive() async {
        guard didStart else { return }
        await refreshPlans()
        await refreshUsage()
        await syncIdentities()
    }

    func refreshUsage() async {
        guard let appUserID, !isRefreshingUsage else { return }
        isRefreshingUsage = true
        defer { isRefreshingUsage = false }
        do {
            let snapshot = try await services.usage.currentUsage(appUserID: appUserID)
            services.sharedState.cacheUsage(snapshot)
            usage = Self.usageInfo(from: snapshot)
        } catch {
            // Keep the last known (cached) value.
            logger.error("Usage refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    func refreshPlans() async {
        guard appUserID != nil else { return }
        do {
            let packages = try await services.billing.currentPackages()
            let active = try await services.billing.activeEntitlementProductIDs()
            plans = Self.planOptions(packages: packages, activeProductIDs: active)
        } catch {
            logger.error("Plan refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Registers the one-time-code identities for the current mailboxes (first one labels them).
    private func syncIdentities() async {
        let addresses = ((try? services.accounts.loadMailboxes()) ?? []).map(\.address)
        await services.identities.syncIdentities(mailboxAddresses: addresses)
    }

    private func reloadAccounts() {
        do {
            accounts = try services.accounts.loadMailboxes().map(Self.mailAccount(from:))
        } catch {
            logger.error("Loading mailboxes failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: SkiPassUIActions

    func addAccount(email: String) async throws -> MailAccount {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = Self.oauthProvider(forEmail: address),
              let endpoint = kind.presetIMAPEndpoint
        else {
            throw SkiPassUIError.needsServerSettings
        }
        // Without a real client ID the provider only shows "Error 401: invalid_client / Access
        // blocked"; do not open its page, report it in the sheet instead.
        guard services.accounts.isSignInConfigured(kind: kind) else {
            logger.error("Sign-in not configured for \(kind.rawValue, privacy: .public): client ID missing in this build")
            throw AppModelError.signInNotConfigured(kind)
        }

        let result = try await services.accounts.signIn(kind: kind, loginHint: address)
        // The account that signed in is the one whose mailbox is read (XOAUTH2 user = this address).
        let signedIn = result.address
        let id = existingMailboxID(address: signedIn) ?? UUID()
        try services.accounts.saveOAuthState(result.authStateData, mailboxID: id)

        let config = MailboxConfig(
            id: id,
            address: signedIn,
            kind: kind,
            imapHost: endpoint.host,
            imapPort: endpoint.port,
            username: signedIn
        )
        try services.accounts.saveMailbox(config)
        reloadAccounts()
        await syncIdentities()
        return Self.mailAccount(from: config)
    }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        let id = existingMailboxID(address: address) ?? UUID()
        let config = MailboxConfig(
            id: id,
            address: address,
            kind: .imap,
            imapHost: settings.incomingHost,
            imapPort: settings.incomingPort,
            username: settings.username
        )
        try services.accounts.savePassword(password, mailboxID: id)
        try services.accounts.saveMailbox(config)
        reloadAccounts()
        await syncIdentities()
        return Self.mailAccount(from: config)
    }

    func deleteAccount(id: UUID) async throws {
        try services.accounts.deleteCredentials(mailboxID: id)
        try services.accounts.deleteMailbox(id: id)
        reloadAccounts()
        await syncIdentities()
    }

    func revealPassword(id: UUID) async -> String? {
        services.accounts.password(mailboxID: id)
    }

    /// Plan rows under "Other plans":
    /// - a paid plan purchases its package. Upgrades take effect at once. A lower tier does not
    ///   replace a higher active one: the highest active tier stays current (the server's rule,
    ///   server/src/plans.ts) until the higher subscription ends.
    /// - Free opens RevenueCat's cancellation path (`showManageSubscriptions`); the plan returns to
    ///   Free when the subscription ends, which the next foreground refresh picks up.
    func selectPlan(id: String) async {
        guard appUserID != nil, !isChangingPlan else { return }
        isChangingPlan = true
        defer { isChangingPlan = false }

        if id == Self.freePlanID {
            guard plans.contains(where: { $0.isCurrent && $0.id != Self.freePlanID }) else { return }
            do {
                // OPEN(plans): with the RevenueCat Test Store there is no in-app cancellation (see
                // LiveBillingServices.showManageSubscriptions); test subscriptions end by themselves.
                try await services.billing.showManageSubscriptions()
            } catch {
                logger.error("Manage subscriptions failed: \(String(describing: error), privacy: .public)")
            }
            await refreshPlans()
            return
        }

        do {
            // Test Store presents its own purchase modal here; nothing else is shown by the app.
            let completed = try await services.billing.purchase(packageID: id)
            guard completed else { return }
        } catch {
            logger.error("Purchase failed: \(String(describing: error), privacy: .public)")
            // Show what the store now holds (e.g. a purchase that completed before a later error).
            await refreshPlans()
            return
        }
        await refreshPlans()
        await refreshUsage()
    }

    // OPEN(enable-autofill): how the user is guided to turn on the AutoFill extension is not decided;
    // nothing is presented for it here.

    private func existingMailboxID(address: String) -> UUID? {
        let mailboxes = (try? services.accounts.loadMailboxes()) ?? []
        return mailboxes.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }?.id
    }
}

/// Errors AppModel reports to the UI; the add-account sheet shows `localizedDescription`.
enum AppModelError: LocalizedError, Equatable {
    /// The build has no (real) OAuth client ID for this provider.
    case signInNotConfigured(ProviderKind)

    var errorDescription: String? {
        switch self {
        case .signInNotConfigured(.google):
            "Google sign-in is not configured in this build."
        case .signInNotConfigured(.microsoft):
            "Microsoft sign-in is not configured in this build."
        case .signInNotConfigured(.imap):
            "Sign-in is not configured in this build."
        }
    }
}

// MARK: - Pure mapping (unit-tested)

extension AppModel {
    static let freePlanID = "free"

    /// Google / Microsoft consumer domains that sign in through the provider's official page.
    /// Everything else continues with the IMAP form.
    // OPEN(provider-detection): Google Workspace / Microsoft 365 custom domains cannot be told
    // apart from other IMAP hosts by the domain alone; they currently get the IMAP form.
    static func oauthProvider(forEmail email: String) -> ProviderKind? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch domain {
        case "gmail.com", "googlemail.com":
            return .google
        case "outlook.com", "hotmail.com", "live.com", "msn.com":
            return .microsoft
        default:
            return nil
        }
    }

    static func mailAccount(from config: MailboxConfig) -> MailAccount {
        switch config.kind {
        case .google:
            return MailAccount(id: config.id, address: config.address, kind: .google, status: .connected)
        case .microsoft:
            return MailAccount(id: config.id, address: config.address, kind: .microsoft, status: .connected)
        case .imap:
            return MailAccount(
                id: config.id,
                address: config.address,
                kind: .imap,
                status: .connected,
                server: ServerSettings(
                    incomingHost: config.imapHost,
                    incomingPort: config.imapPort,
                    username: config.username
                )
            )
        }
    }

    static func usageInfo(from snapshot: UsageSnapshot) -> UsageInfo {
        UsageInfo(used: snapshot.used, limit: snapshot.limit, resetsAt: snapshot.resetsAt)
    }

    /// Free plus the current offering's packages (cheapest first). Exactly one option is current:
    /// the highest-priced package whose product grants an active entitlement, or Free when none does.
    ///
    /// Several packages can be active at once: the RevenueCat Test Store has no product change, so
    /// buying Pro while Standard is active adds a second subscription (and on the App Store a
    /// downgrade stays pending until renewal). The highest tier wins, as on the server
    /// (server/src/plans.ts PAID_PLANS order); price is the app's proxy for tier.
    static func planOptions(packages: [StorePackageInfo], activeProductIDs: Set<String>) -> [PlanOption] {
        let sorted = packages.sorted { $0.price < $1.price }
        let currentID = sorted.last { activeProductIDs.contains($0.productID) }?.id
        let paid = sorted.enumerated().map { index, package in
            PlanOption(
                id: package.id,
                name: package.title,
                tagline: package.description,
                priceText: package.priceString,
                isCurrent: package.id == currentID,
                // OPEN(plans): plan set is not decided; icons follow the mockup order
                // (lowest paid tier = stack, higher tiers = crown).
                systemImage: index == 0 ? "square.stack.3d.up.fill" : "crown.fill"
            )
        }
        let free = PlanOption(
            id: freePlanID,
            // OPEN(copy): SkiPassUI.Copy has no Free-plan strings (Copy is internal and plan names are [Open]).
            // Name mirrors the server plan id "free"; tagline and price are left empty until copy exists.
            name: "Free",
            tagline: "",
            priceText: "",
            isCurrent: !paid.contains(where: \.isCurrent),
            systemImage: "person.fill"
        )
        return [free] + paid
    }
}
