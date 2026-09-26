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
    }

    /// Called when the app returns to the foreground.
    func didBecomeActive() async {
        guard didStart else { return }
        await refreshUsage()
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
        return Self.mailAccount(from: config)
    }

    func deleteAccount(id: UUID) async throws {
        try services.accounts.deleteCredentials(mailboxID: id)
        try services.accounts.deleteMailbox(id: id)
        reloadAccounts()
    }

    func revealPassword(id: UUID) async -> String? {
        services.accounts.password(mailboxID: id)
    }

    func selectPlan(id: String) async {
        guard appUserID != nil else { return }
        // OPEN(plans): moving back to Free (cancelling a subscription) is not specified; tapping Free does nothing.
        guard id != Self.freePlanID else { return }
        do {
            // Test Store presents its own purchase modal here; nothing else is shown by the app.
            let completed = try await services.billing.purchase(packageID: id)
            guard completed else { return }
        } catch {
            logger.error("Purchase failed: \(String(describing: error), privacy: .public)")
            return
        }
        await refreshPlans()
        await refreshUsage()
    }

    func openSettings() {
        // OPEN(settings): settings screen contents are not decided (SPEC_v2 §11.1); intentionally a no-op.
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

    /// Free plus the current offering's packages (cheapest first). A package is current when one
    /// of the customer's active entitlements was granted by its product; Free is current otherwise.
    static func planOptions(packages: [StorePackageInfo], activeProductIDs: Set<String>) -> [PlanOption] {
        let sorted = packages.sorted { $0.price < $1.price }
        let paid = sorted.enumerated().map { index, package in
            PlanOption(
                id: package.id,
                name: package.title,
                tagline: package.description,
                priceText: package.priceString,
                isCurrent: activeProductIDs.contains(package.productID),
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
