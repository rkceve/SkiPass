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
    /// False when this build has no RevenueCat key ("Plans are unavailable in this build.").
    private(set) var plansAvailable = true

    @ObservationIgnored private let services: AppServicesBundle
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var appUserID: String?
    @ObservationIgnored private var billingConfigured = false
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var didFinishStart = false
    /// A plan change (purchase sheet / subscription management) is in progress; further taps are ignored.
    @ObservationIgnored private var isChangingPlan = false

    // Last known plan inputs. Failed refreshes keep them (docs/ARCHITECTURE.md §2).
    @ObservationIgnored private var packages: [StorePackageInfo] = []
    @ObservationIgnored private var entitlements: EntitlementSnapshot?
    /// The server's `/v1/usage.plan` (source of truth for the current plan); nil when unknown.
    @ObservationIgnored private var serverPlan: PlanTier?

    // Refreshes run one at a time; a request made while one runs is re-run after it (never dropped).
    @ObservationIgnored private var usageRefresher: SerialRefresher!
    @ObservationIgnored private var plansRefresher: SerialRefresher!
    @ObservationIgnored private var identityRefresher: SerialRefresher!

    @ObservationIgnored private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "AppModel")

    init(services: AppServicesBundle, now: @escaping () -> Date = Date.init) {
        self.services = services
        self.now = now
        self.plans = [PlanOption.free(isCurrent: true)]
        usageRefresher = SerialRefresher { [weak self] in await self?.performUsageRefresh() }
        plansRefresher = SerialRefresher { [weak self] in await self?.performPlansRefresh() }
        identityRefresher = SerialRefresher { [weak self] in await self?.performIdentitySync() }
    }

    // MARK: Lifecycle

    /// Loads local state, configures RevenueCat and fetches plans and usage. Runs once.
    func start() async {
        guard !didStart else { return }
        didStart = true

        reloadAccounts()
        if let cached = services.sharedState.cachedUsage() {
            usage = Self.usageInfo(from: cached, now: now())
            serverPlan = PlanTier(rawValue: cached.plan)
        }

        let userID: String
        if let revenueCatID = services.billing.configure() {
            billingConfigured = true
            userID = revenueCatID
        } else {
            // No RevenueCat key: a stable local ID so the extension can still ask the server.
            plansAvailable = false
            userID = Self.localAppUserID(existing: services.sharedState.appUserID())
        }
        appUserID = userID
        services.sharedState.setAppUserID(userID)
        rebuildPlans()

        await refreshPlans()
        await refreshUsage()
        await syncIdentities()
        didFinishStart = true
    }

    /// Called when the app returns to the foreground (e.g. from subscription management or from
    /// Settings after enabling AutoFill, which is when the identity store becomes writable).
    /// Ignored until `start()` has finished (at cold launch `start()` already refreshes everything).
    func didBecomeActive() async {
        guard didFinishStart else { return }
        await refreshPlans()
        await refreshUsage()
        await syncIdentities()
    }

    func refreshUsage() async {
        await usageRefresher.run()
    }

    func refreshPlans() async {
        await plansRefresher.run()
    }

    /// Registers the one-time-code identities for the current mailboxes (first one labels them).
    private func syncIdentities() async {
        await identityRefresher.run()
    }

    private func performUsageRefresh() async {
        // A local ID is unknown to RevenueCat, so the server answers 401 unknown_user: nothing to show.
        guard let appUserID, !appUserID.hasPrefix(Self.localAppUserIDPrefix) else { return }
        do {
            let snapshot = try await services.usage.currentUsage(appUserID: appUserID)
            guard PlanTier(rawValue: snapshot.plan) != nil else {
                // plan "unknown" (limit 0): the server could not reach RevenueCat and has nothing
                // cached. Keep the last known usage and plan.
                logger.notice("Usage plan unknown on the server; keeping the last known values")
                return
            }
            services.sharedState.cacheUsage(snapshot)
            usage = Self.usageInfo(from: snapshot, now: now())
            serverPlan = PlanTier(rawValue: snapshot.plan)
            rebuildPlans()
        } catch {
            // Keep the last known (cached) values.
            logger.error("Usage refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func performPlansRefresh() async {
        guard billingConfigured else { return }
        do {
            packages = try await services.billing.currentPackages()
        } catch {
            logger.error("Offering refresh failed: \(String(describing: error), privacy: .public)")
        }
        do {
            entitlements = try await services.billing.entitlements()
        } catch {
            logger.error("Entitlement refresh failed: \(String(describing: error), privacy: .public)")
        }
        rebuildPlans()
    }

    /// Reads the mailbox list right before writing, so the newest list always wins.
    private func performIdentitySync() async {
        let addresses = ((try? services.accounts.loadMailboxes()) ?? []).map(\.address)
        await services.identities.syncIdentities(mailboxAddresses: addresses)
    }

    private var currentTier: PlanTier {
        Self.currentTier(serverPlan: serverPlan, activeEntitlements: entitlements?.active)
    }

    private func rebuildPlans() {
        plans = Self.planOptions(
            packages: billingConfigured ? packages : [],
            currentTier: currentTier,
            entitlementProductIDs: entitlements?.productIDs ?? [:]
        )
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
            throw kind == .google ? SkiPassUIError.googleSignInNotConfigured : SkiPassUIError.microsoftSignInNotConfigured
        }

        let result: OAuthSignInResult
        do {
            result = try await services.accounts.signIn(kind: kind, loginHint: address)
        } catch {
            if Self.isUserCancellation(error) {
                logger.notice("Sign-in cancelled by the user")
                throw CancellationError()
            }
            logger.error("Sign-in failed: \(String(describing: error), privacy: .public)")
            throw SkiPassUIError.signInFailed
        }

        // The account that signed in is the one whose mailbox is read (XOAUTH2 user = this address).
        let signedIn = result.address
        let config = MailboxConfig(
            id: existingMailbox(address: signedIn)?.id ?? UUID(),
            address: signedIn,
            kind: kind,
            imapHost: endpoint.host,
            imapPort: endpoint.port,
            username: signedIn
        )
        try await saveMailbox(config) {
            try services.accounts.saveOAuthState(result.authStateData, mailboxID: config.id)
        }
        return Self.mailAccount(from: config)
    }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        let config = MailboxConfig(
            id: existingMailbox(address: address)?.id ?? UUID(),
            address: address,
            kind: .imap,
            imapHost: settings.incomingHost,
            imapPort: settings.incomingPort,
            username: settings.username
        )
        try await saveMailbox(config) {
            try services.accounts.savePassword(password, mailboxID: config.id)
        }
        return Self.mailAccount(from: config)
    }

    /// Writes the mailbox's secret, then its config. If the config cannot be saved, a secret that
    /// did not exist before is removed again (no orphan Keychain item). When the mailbox changes
    /// kind (IMAP <-> Google / Microsoft), the other kind's secret is deleted.
    private func saveMailbox(_ config: MailboxConfig, writeSecret: () throws -> Void) async throws {
        let previous = existingMailbox(address: config.address)
        do {
            try writeSecret()
        } catch {
            logger.error("Saving the secret failed: \(String(describing: error), privacy: .public)")
            throw SkiPassUIError.saveFailed
        }
        do {
            try services.accounts.saveMailbox(config)
        } catch {
            logger.error("Saving the mailbox failed: \(String(describing: error), privacy: .public)")
            if previous == nil || previous?.kind.usesOAuth != config.kind.usesOAuth {
                try? deleteSecret(usesOAuth: config.kind.usesOAuth, mailboxID: config.id)
            }
            throw SkiPassUIError.saveFailed
        }
        if let previous, previous.kind.usesOAuth != config.kind.usesOAuth {
            do {
                try deleteSecret(usesOAuth: previous.kind.usesOAuth, mailboxID: config.id)
            } catch {
                logger.error("Deleting the replaced secret failed: \(String(describing: error), privacy: .public)")
            }
        }
        reloadAccounts()
        await syncIdentities()
    }

    private func deleteSecret(usesOAuth: Bool, mailboxID: UUID) throws {
        if usesOAuth {
            try services.accounts.deleteOAuthState(mailboxID: mailboxID)
        } else {
            try services.accounts.deletePassword(mailboxID: mailboxID)
        }
    }

    func deleteAccount(id: UUID) async throws {
        do {
            try services.accounts.deleteCredentials(mailboxID: id)
            try services.accounts.deleteMailbox(id: id)
        } catch {
            logger.error("Deleting the mailbox failed: \(String(describing: error), privacy: .public)")
            reloadAccounts()
            throw SkiPassUIError.deleteFailed
        }
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
        guard billingConfigured, !isChangingPlan else { return }
        isChangingPlan = true
        defer { isChangingPlan = false }

        if id == Self.freePlanID {
            guard currentTier != .free else { return }
            do {
                // docs/ARCHITECTURE.md §2: a Test Store subscription cannot be cancelled here; it expires by
                // itself (see LiveBillingServices.showManageSubscriptions).
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
        // The server's plan predates the purchase: use the entitlements until it answers again.
        serverPlan = nil
        await refreshPlans()
        await refreshUsage()
    }

    /// The AutoFill extension was just turned on (`AutoFillSetupModel.onTurnedOn`): the identity
    /// store only accepts identities while it is on, so register them now.
    func autoFillDidTurnOn() async {
        await syncIdentities()
    }

    private func existingMailbox(address: String) -> MailboxConfig? {
        let mailboxes = (try? services.accounts.loadMailboxes()) ?? []
        return mailboxes.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
    }
}

/// Runs `work` one at a time. A `run()` while one is in flight waits for it and, if it was
/// requested after that run started, for one more run, so the newest state always lands last.
@MainActor
final class SerialRefresher {
    private let work: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var requested = 0

    init(_ work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    func run() async {
        requested += 1
        if let task {
            await task.value
            return
        }
        let task = Task { @MainActor in
            var handled = 0
            while handled < self.requested {
                handled = self.requested
                await self.work()
            }
            self.task = nil
        }
        self.task = task
        await task.value
    }
}

private extension ProviderKind {
    var usesOAuth: Bool { self != .imap }
}

/// Paid tiers in the server's order (server/src/plans.ts: entitlement lookup key = plan id).
enum PlanTier: String, Comparable, Sendable {
    case free
    case standard
    case pro

    private var rank: Int {
        switch self {
        case .free: 0
        case .standard: 1
        case .pro: 2
        }
    }

    static func < (lhs: PlanTier, rhs: PlanTier) -> Bool { lhs.rank < rhs.rank }
}

// MARK: - Pure mapping (unit-tested)

extension AppModel {
    static let freePlanID = "free"
    static let localAppUserIDPrefix = "local:"

    /// The stored local ID when there is one, else a new random `local:<uuid>`.
    static func localAppUserID(existing: String?) -> String {
        if let existing, existing.hasPrefix(localAppUserIDPrefix) { return existing }
        return localAppUserIDPrefix + UUID().uuidString.lowercased()
    }

    /// True for the user closing the provider's sign-in page: AppAuth
    /// `OIDErrorCodeUserCanceledAuthorizationFlow` (-3 in `OIDGeneralErrorDomain`) or the
    /// underlying `ASWebAuthenticationSessionError.canceledLogin`.
    static func isUserCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return (nsError.domain == "org.openid.appauth.general" && nsError.code == -3)
            || (nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1)
    }

    /// Google / Microsoft consumer domains that sign in through the provider's official page.
    /// Everything else continues with the IMAP form. Google Workspace / Microsoft 365 custom domains
    /// cannot be told apart from other IMAP hosts by the domain alone, so they get the IMAP form too.
    static func oauthProvider(forEmail email: String) -> ProviderKind? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if domain == "gmail.com" || domain == "googlemail.com" { return .google }
        if MicrosoftConsumerDomains.all.contains(domain) { return .microsoft }
        return nil
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

    /// A snapshot whose reset date has passed describes last month: show a fresh month instead
    /// (nothing used, next reset at the start of the next UTC month, as the server counts).
    static func usageInfo(from snapshot: UsageSnapshot, now: Date) -> UsageInfo {
        guard snapshot.resetsAt <= now else {
            return UsageInfo(used: snapshot.used, limit: snapshot.limit, resetsAt: snapshot.resetsAt)
        }
        return UsageInfo(used: 0, limit: snapshot.limit, resetsAt: nextUTCMonthStart(after: now))
    }

    static func nextUTCMonthStart(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: 1, to: monthStart) ?? date
    }

    /// Current plan: the server's `/v1/usage.plan` when known; otherwise the highest
    /// active RevenueCat entitlement by lookup key (`pro` > `standard`, never by price); else Free.
    static func currentTier(serverPlan: PlanTier?, activeEntitlements: Set<String>?) -> PlanTier {
        if let serverPlan { return serverPlan }
        let paid = (activeEntitlements ?? []).compactMap(PlanTier.init(rawValue:)).filter { $0 != .free }
        return paid.max() ?? .free
    }

    /// Tier of an offering package: the entitlement whose product it is, else the tier named in
    /// its product / package identifier (e.g. `skipass_pro_monthly`).
    static func tier(of package: StorePackageInfo, entitlementProductIDs: [String: String]) -> PlanTier? {
        if let entitlement = entitlementProductIDs.first(where: { $0.value == package.productID })?.key,
           let tier = PlanTier(rawValue: entitlement), tier != .free {
            return tier
        }
        let tokens = Set((package.productID + " " + package.id).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if tokens.contains(PlanTier.pro.rawValue) { return .pro }
        if tokens.contains(PlanTier.standard.rawValue) { return .standard }
        return nil
    }

    /// Free plus the current offering's packages (cheapest first). Exactly one option is current:
    /// the package of `currentTier` (the one whose product backs that entitlement when known), or
    /// Free. A paid current tier with no package in the offering still gets a (name-only) row.
    ///
    /// Several packages can be active at once: the RevenueCat Test Store has no product change, so
    /// buying Pro while Standard is active adds a second subscription (and on the App Store a
    /// downgrade stays pending until renewal). The highest tier wins, as on the server.
    static func planOptions(
        packages: [StorePackageInfo],
        currentTier: PlanTier,
        entitlementProductIDs: [String: String]
    ) -> [PlanOption] {
        let sorted = packages.sorted { $0.price < $1.price }
        let tiers = sorted.map { tier(of: $0, entitlementProductIDs: entitlementProductIDs) }
        var currentID: String?
        if currentTier != .free {
            let productID = entitlementProductIDs[currentTier.rawValue]
            currentID = sorted.first { productID != nil && $0.productID == productID }?.id
                ?? zip(sorted, tiers).first { $0.1 == currentTier }?.0.id
        }
        var paid = zip(sorted, tiers).map { package, tier in
            PlanOption(
                id: package.id,
                name: package.title,
                // Copy's tagline for the tier; the store description only for an unknown tier.
                tagline: tier.flatMap { PlanOption.paidPlanTagline(planID: $0.rawValue) } ?? package.description,
                priceText: package.priceString,
                isCurrent: package.id == currentID,
                systemImage: systemImage(for: tier)
            )
        }
        if currentTier != .free, currentID == nil, let name = PlanOption.paidPlanName(planID: currentTier.rawValue) {
            paid.insert(PlanOption(
                id: "plan.\(currentTier.rawValue)",
                name: name,
                tagline: PlanOption.paidPlanTagline(planID: currentTier.rawValue) ?? "",
                priceText: "",
                isCurrent: true,
                systemImage: systemImage(for: currentTier)
            ), at: 0)
        }
        return [PlanOption.free(isCurrent: currentTier == .free)] + paid
    }

    private static func systemImage(for tier: PlanTier?) -> String {
        tier == .pro ? "crown.fill" : "square.stack.3d.up.fill"
    }
}
