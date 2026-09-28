// Compiled only by a unit-test target that defines SKIPASS_APP_TESTS; the app target
// (sources: ios/App) compiles this file to nothing.
#if SKIPASS_APP_TESTS
import Foundation
import SkiPassModels
import SkiPassUI
import Testing
@testable import SkiPass

// Unit tests for AppModel with in-memory fakes of the App-local service seams.

@MainActor
private final class FakeAccounts: AccountServices {
    var mailboxes: [MailboxConfig] = []
    var passwords: [UUID: String] = [:]
    var signIns: [(kind: ProviderKind, loginHint: String)] = []
    var oauthStates: [UUID: Data] = [:]
    var deletedCredentials: [UUID] = []
    var signInError: Error?
    /// Address the provider reports as signed in; nil = the login hint.
    var signedInAddress: String?
    var saveMailboxError: Error?
    var deleteError: Error?

    func loadMailboxes() throws -> [MailboxConfig] { mailboxes }

    func saveMailbox(_ mailbox: MailboxConfig) throws {
        if let saveMailboxError { throw saveMailboxError }
        if let index = mailboxes.firstIndex(where: { $0.id == mailbox.id }) {
            mailboxes[index] = mailbox
        } else {
            mailboxes.append(mailbox)
        }
    }

    func deleteMailbox(id: UUID) throws { mailboxes.removeAll { $0.id == id } }
    func savePassword(_ password: String, mailboxID: UUID) throws { passwords[mailboxID] = password }
    func password(mailboxID: UUID) -> String? { passwords[mailboxID] }

    func deletePassword(mailboxID: UUID) throws { passwords[mailboxID] = nil }
    func deleteOAuthState(mailboxID: UUID) throws { oauthStates[mailboxID] = nil }

    func deleteCredentials(mailboxID: UUID) throws {
        if let deleteError { throw deleteError }
        deletedCredentials.append(mailboxID)
        passwords[mailboxID] = nil
        oauthStates[mailboxID] = nil
    }

    /// Providers whose client ID is missing in the simulated build.
    var unconfiguredKinds: Set<ProviderKind> = []

    func isSignInConfigured(kind: ProviderKind) -> Bool { !unconfiguredKinds.contains(kind) }

    func signIn(kind: ProviderKind, loginHint: String) async throws -> OAuthSignInResult {
        if let signInError { throw signInError }
        signIns.append((kind, loginHint))
        return OAuthSignInResult(address: signedInAddress ?? loginHint, authStateData: Data("state".utf8))
    }

    func saveOAuthState(_ data: Data, mailboxID: UUID) throws { oauthStates[mailboxID] = data }
}

@MainActor
private final class FakeBilling: BillingServices {
    var appUserID: String? = "$RCAnonymousID:test"
    var packages: [StorePackageInfo] = []
    /// Active product identifiers; each backs the entitlement in `entitlementByProduct`.
    var active: Set<String> = []
    var entitlementByProduct: [String: String] = [
        "skipass_standard_monthly": "standard", "skipass_standard_annual": "standard",
        "skipass_pro_monthly": "pro",
    ]
    var offeringsError: Error?
    var customerInfoError: Error?
    var purchased: [String] = []
    var purchaseCompletes = true
    var activeAfterPurchase: Set<String>?
    /// Test Store behaviour: a completed purchase adds its product to the active set
    /// (no product change; earlier subscriptions stay active).
    var addsPurchasedProduct = false
    var purchaseError: Error?
    var manageSubscriptionsCalls = 0
    /// When true, purchases wait until `releasePurchases()` (a purchase sheet that is still open).
    var holdPurchases = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func configure() -> String? { appUserID }
    func currentPackages() async throws -> [StorePackageInfo] {
        if let offeringsError { throw offeringsError }
        return packages
    }

    func entitlements() async throws -> EntitlementSnapshot {
        if let customerInfoError { throw customerInfoError }
        return entitlementSnapshot
    }

    var entitlementSnapshot: EntitlementSnapshot {
        let activeIDs = Set(active.compactMap { entitlementByProduct[$0] })
        var products: [String: String] = [:]
        for product in active.sorted() {
            if let entitlement = entitlementByProduct[product] { products[entitlement] = product }
        }
        return EntitlementSnapshot(active: activeIDs, productIDs: products)
    }

    /// The server's rule (server/src/plans.ts): highest active entitlement, else free.
    var serverPlan: String {
        let ids = entitlementSnapshot.active
        return ids.contains("pro") ? "pro" : ids.contains("standard") ? "standard" : "free"
    }

    func purchase(packageID: String) async throws -> Bool {
        purchased.append(packageID)
        if holdPurchases {
            await withCheckedContinuation { held.append($0) }
        }
        if let purchaseError { throw purchaseError }
        if purchaseCompletes, let activeAfterPurchase { active = activeAfterPurchase }
        if purchaseCompletes, addsPurchasedProduct,
           let product = packages.first(where: { $0.id == packageID })?.productID {
            active.insert(product)
        }
        return purchaseCompletes
    }

    func releasePurchases() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func showManageSubscriptions() async throws {
        manageSubscriptionsCalls += 1
    }
}

@MainActor
private final class FakeIdentities: IdentityServices {
    /// Address lists in the order the syncs finished (the last one is what the system keeps).
    var syncs: [[String]] = []
    var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func syncIdentities(mailboxAddresses: [String]) async {
        if hold {
            await withCheckedContinuation { held.append($0) }
        }
        syncs.append(mailboxAddresses)
    }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeUsage: UsageServices {
    var snapshot = UsageSnapshot(plan: "free", used: 3, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
    /// When set, the reported plan follows it (the server looks the plan up in RevenueCat).
    var planSource: (@MainActor () -> String)?
    var calls: [String] = []
    var error: Error?

    /// When true, calls wait until `release()` (a slow request in flight).
    var hold = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldCount: Int { held.count }

    func currentUsage(appUserID: String) async throws -> UsageSnapshot {
        calls.append(appUserID)
        var answer = snapshot
        if let planSource { answer.plan = planSource() }
        if hold {
            await withCheckedContinuation { held.append($0) }
        }
        if let error { throw error }
        return answer
    }

    func release() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeSharedState: SharedStateServices {
    var storedAppUserID: String?
    var usage: UsageSnapshot?

    func appUserID() -> String? { storedAppUserID }
    func setAppUserID(_ appUserID: String) { storedAppUserID = appUserID }
    func cachedUsage() -> UsageSnapshot? { usage }
    func cacheUsage(_ snapshot: UsageSnapshot) { usage = snapshot }
}

private struct Boom: Error {}

@MainActor
private struct Harness {
    let accounts = FakeAccounts()
    let billing = FakeBilling()
    let usage = FakeUsage()
    let shared = FakeSharedState()
    let identities = FakeIdentities()

    init() {
        // Like the real server, /v1/usage reports the plan RevenueCat has for this user.
        usage.planSource = { [billing] in billing.serverPlan }
    }

    func makeModel(now: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> AppModel {
        AppModel(services: AppServicesBundle(accounts: accounts, billing: billing, usage: usage,
                                             sharedState: shared, identities: identities),
                 now: { now })
    }
}

private let standard = StorePackageInfo(
    id: "$rc_monthly", productID: "skipass_standard_monthly", title: "Standard",
    description: "More fills", priceString: "$2.99", price: 2.99)
private let pro = StorePackageInfo(
    id: "pro_monthly", productID: "skipass_pro_monthly", title: "Pro",
    description: "Most fills", priceString: "$9.99", price: 9.99)

@MainActor
struct ProviderDetectionTests {
    @Test(arguments: ["a@gmail.com", "A@GMAIL.COM", "a@googlemail.com", " a@gmail.com "])
    func googleDomains(_ email: String) {
        #expect(AppModel.oauthProvider(forEmail: email) == .google)
    }

    @Test(arguments: ["a@outlook.com", "a@hotmail.com", "a@live.com", "a@msn.com"])
    func microsoftDomains(_ email: String) {
        #expect(AppModel.oauthProvider(forEmail: email) == .microsoft)
    }

    /// Microsoft consumer domains under other TLDs.
    @Test(arguments: ["a@outlook.jp", "a@outlook.com.au", "a@hotmail.co.jp", "a@hotmail.co.uk", "a@hotmail.fr",
                      "a@live.jp", "a@live.co.uk", "a@msn.co.jp", "a@outlook.de"])
    func microsoftRegionalDomains(_ email: String) {
        #expect(AppModel.oauthProvider(forEmail: email) == .microsoft)
    }

    @Test(arguments: ["a@icloud.com", "a@yahoo.com", "a@myshop.jp", "a@mail.gmail.com", "no-at-sign"])
    func otherDomainsNeedIMAP(_ email: String) {
        #expect(AppModel.oauthProvider(forEmail: email) == nil)
    }
}

@MainActor
struct MappingTests {
    @Test func oauthMailboxHasNoServerSettings() {
        let config = MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com", imapPort: 993, username: "a@gmail.com")
        let account = AppModel.mailAccount(from: config)
        #expect(account.id == config.id)
        #expect(account.kind == .google)
        #expect(account.server == nil)
    }

    @Test func imapMailboxMapsIncomingSettingsOnly() {
        let config = MailboxConfig(address: "info@myshop.jp", kind: .imap, imapHost: "mail.myshop.jp", imapPort: 993, username: "info")
        let account = AppModel.mailAccount(from: config)
        #expect(account.kind == .imap)
        #expect(account.server == ServerSettings(incomingHost: "mail.myshop.jp", incomingPort: 993, username: "info"))
    }

    private static let bothProducts = ["standard": "skipass_standard_monthly", "pro": "skipass_pro_monthly"]

    @Test func plansWithoutEntitlementMakeFreeCurrent() {
        let plans = AppModel.planOptions(packages: [pro, standard], currentTier: .free, entitlementProductIDs: [:])
        #expect(plans.map(\.id) == ["free", "$rc_monthly", "pro_monthly"])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["free"])
        #expect(plans[1].name == "Standard")
        #expect(plans[1].tagline == "More fills")
        #expect(plans[1].priceText == "$2.99")
        #expect(plans[1].systemImage == "square.stack.3d.up.fill")
        #expect(plans[2].systemImage == "crown.fill")
    }

    /// The Free row has its own name, tagline and price (not blank next to paid rows).
    @Test func freeRowIsNotBlank() {
        let free = AppModel.planOptions(packages: [standard], currentTier: .standard, entitlementProductIDs: [:])[0]
        #expect(free.id == "free")
        #expect(!free.name.isEmpty && !free.tagline.isEmpty && !free.priceText.isEmpty)
    }

    /// Tier comes from the entitlement lookup key (pro > standard), never the price
    /// (annual Standard costs more than monthly Pro).
    @Test func tierIsNotInferredFromPrice() {
        let standardAnnual = StorePackageInfo(
            id: "$rc_annual", productID: "skipass_standard_annual", title: "Standard",
            description: "More fills", priceString: "$99.99", price: 99.99)
        let tier = AppModel.currentTier(serverPlan: nil, activeEntitlements: ["standard", "pro"])
        #expect(tier == .pro)
        let plans = AppModel.planOptions(
            packages: [standardAnnual, pro], currentTier: tier,
            entitlementProductIDs: ["standard": "skipass_standard_annual", "pro": "skipass_pro_monthly"])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])
    }

    /// The server's plan wins over the on-device entitlements; "unknown" falls back to them.
    @Test func serverPlanIsTheSourceOfTruth() {
        #expect(AppModel.currentTier(serverPlan: .standard, activeEntitlements: ["pro"]) == .standard)
        #expect(AppModel.currentTier(serverPlan: PlanTier(rawValue: "unknown"), activeEntitlements: ["pro"]) == .pro)
        #expect(AppModel.currentTier(serverPlan: nil, activeEntitlements: nil) == .free)
    }

    @Test func activeEntitlementMarksItsPackageCurrent() {
        let plans = AppModel.planOptions(packages: [standard, pro], currentTier: .pro,
                                         entitlementProductIDs: ["pro": "skipass_pro_monthly"])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])
    }

    /// Without entitlement data the package is matched by the tier named in its identifiers.
    @Test func packageTierFromIdentifiersWhenNoEntitlementKnown() {
        let plans = AppModel.planOptions(packages: [standard, pro], currentTier: .standard, entitlementProductIDs: [:])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["$rc_monthly"])
    }

    /// A4: a paid plan whose product is no longer in the current offering is still shown as current.
    @Test func currentPaidTierWithoutPackageStillShown() {
        let plans = AppModel.planOptions(packages: [standard], currentTier: .pro,
                                         entitlementProductIDs: ["pro": "skipass_pro_legacy"])
        let current = plans.filter(\.isCurrent)
        #expect(current.count == 1)
        #expect(current.first?.name == "Pro")
        #expect(plans.filter { !$0.isCurrent }.map(\.id) == ["free", "$rc_monthly"])
    }

    /// Regression (device, v0.1.4): with Standard and Pro both active (Test Store: buying Pro adds a
    /// second subscription), both were marked current; the screen showed Standard and hid Pro.
    @Test func highestActiveTierIsTheOnlyCurrentPlan() {
        let tier = AppModel.currentTier(serverPlan: nil, activeEntitlements: ["standard", "pro"])
        let plans = AppModel.planOptions(packages: [standard, pro], currentTier: tier,
                                         entitlementProductIDs: Self.bothProducts)
        #expect(plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])
        #expect(plans.filter { !$0.isCurrent }.map(\.id) == ["free", "$rc_monthly"])
    }

    /// A cached month that has ended shows a fresh month.
    @Test func endedMonthShowsFreshUsage() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)  // 2026-10-03 UTC
        let lastMonth = UsageSnapshot(plan: "free", used: 7, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_790_812_800))  // 2026-10-01
        let info = AppModel.usageInfo(from: lastMonth, now: now)
        #expect(info.used == 0)
        #expect(info.limit == 10)
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))  // 2026-11-01 00:00 UTC

        let current = UsageSnapshot(plan: "free", used: 7, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_793_491_200))
        #expect(AppModel.usageInfo(from: current, now: now) == UsageInfo(used: 7, limit: 10, resetsAt: current.resetsAt))
    }

    /// Closing the provider page is a cancellation, other failures are not.
    @Test func userCancellationIsRecognised() {
        #expect(AppModel.isUserCancellation(NSError(domain: "org.openid.appauth.general", code: -3)))
        #expect(AppModel.isUserCancellation(NSError(domain: "com.apple.AuthenticationServices.WebAuthenticationSession", code: 1)))
        #expect(!AppModel.isUserCancellation(NSError(domain: "org.openid.appauth.general", code: -5)))
        #expect(!AppModel.isUserCancellation(Boom()))
    }

    /// The committed example placeholders mean "not configured".
    @Test func examplePlaceholdersAreNotConfiguration() {
        let placeholders = AppConfiguration(info: [
            "SkiPassServerURL": "https://skipass.example.invalid",
            "SkiPassAppToken": "example-app-token",
            "RevenueCatAPIKey": "appl_example",
        ])
        #expect(placeholders.serverURL == nil)
        #expect(placeholders.appToken == nil)
        #expect(placeholders.revenueCatAPIKey == nil)

        let unset = AppConfiguration(info: ["SkiPassAppToken": "$(SKIPASS_APP_TOKEN)", "RevenueCatAPIKey": " "])
        #expect(unset.appToken == nil)
        #expect(unset.revenueCatAPIKey == nil)

        let real = AppConfiguration(info: [
            "SkiPassServerURL": "https://skipass-server.vercel.app",
            "SkiPassAppToken": "t0k3n",
            "RevenueCatAPIKey": "test_abc",
        ])
        #expect(real.serverURL == URL(string: "https://skipass-server.vercel.app"))
        #expect(real.appToken == "t0k3n")
        #expect(real.revenueCatAPIKey == "test_abc")
    }
}

@MainActor
struct AppModelTests {
    @Test func startConfiguresBillingSharesUserIDAndLoadsEverything() async {
        let h = Harness()
        h.accounts.mailboxes = [MailboxConfig(address: "a@gmail.com", kind: .google, imapHost: "imap.gmail.com", imapPort: 993, username: "a@gmail.com")]
        h.billing.packages = [standard]
        let model = h.makeModel()

        await model.start()

        #expect(h.shared.storedAppUserID == "$RCAnonymousID:test")
        #expect(model.accounts.map(\.address) == ["a@gmail.com"])
        #expect(model.plans.map(\.id) == ["free", "$rc_monthly"])
        #expect(h.usage.calls == ["$RCAnonymousID:test"])
        #expect(model.usage == UsageInfo(used: 3, limit: 10, resetsAt: h.usage.snapshot.resetsAt))
        #expect(h.shared.usage == h.usage.snapshot)
    }

    @Test func cachedUsageIsKeptWhenServerFails() async {
        let h = Harness()
        let cached = UsageSnapshot(plan: "free", used: 1, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
        h.shared.usage = cached
        h.usage.error = Boom()
        let model = h.makeModel()

        await model.start()

        #expect(model.usage == UsageInfo(used: 1, limit: 10, resetsAt: cached.resetsAt))
    }

    /// RevenueCat and the server unreachable at launch: a Pro subscriber still sees Pro
    /// (from the cached server usage), and no "unavailable" message (the build has a key).
    @Test func offlineLaunchKeepsTheLastKnownPlan() async {
        let h = Harness()
        h.shared.usage = UsageSnapshot(plan: "pro", used: 535, limit: 1000, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
        h.billing.offeringsError = Boom()
        h.billing.customerInfoError = Boom()
        h.usage.error = Boom()
        let model = h.makeModel()

        await model.start()

        #expect(model.plansAvailable)
        #expect(model.plans.filter(\.isCurrent).map(\.name) == ["Pro"])
        #expect(model.usage?.limit == 1000)
    }

    /// A failed refresh keeps the plans that were already loaded.
    @Test func failedRefreshKeepsLoadedPlans() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.active = ["skipass_standard_monthly"]
        let model = h.makeModel()
        await model.start()
        let loaded = model.plans

        h.billing.offeringsError = Boom()
        h.billing.customerInfoError = Boom()
        h.usage.error = Boom()
        await model.didBecomeActive()

        #expect(model.plans == loaded)
        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["$rc_monthly"])
    }

    /// The plan the server enforces is the plan shown, even if the device disagrees.
    @Test func serverPlanDecidesTheCurrentPlan() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.active = ["skipass_pro_monthly"]
        h.usage.planSource = nil
        h.usage.snapshot = UsageSnapshot(plan: "free", used: 7, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
        let model = h.makeModel()

        await model.start()

        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["free"])
        #expect(model.usage?.limit == 10)
    }

    /// Without a RevenueCat key the app writes a random `local:<uuid>` ID (kept across launches)
    /// for the extension, and the Plan tab says plans are unavailable.
    @Test func withoutRevenueCatALocalUserIDIsWrittenAndKept() async {
        let h = Harness()
        h.billing.appUserID = nil
        let model = h.makeModel()

        await model.start()

        let id = h.shared.storedAppUserID
        #expect(id?.hasPrefix("local:") == true)
        #expect(id.map { UUID(uuidString: String($0.dropFirst("local:".count))) != nil } == true)
        #expect(!model.plansAvailable)
        #expect(model.plans.map(\.id) == ["free"])
        #expect(model.plans.first?.isCurrent == true)

        await h.makeModel().start()
        #expect(h.shared.storedAppUserID == id)
    }

    /// Server contract (F3): `plan: "unknown"` with `limit: 0` means RevenueCat was unreachable and
    /// nothing is cached; the app keeps its last known usage and plan (no "0 of 0 left", not Free).
    @Test func unknownServerPlanKeepsTheLastKnownUsage() async {
        let h = Harness()
        let cached = UsageSnapshot(plan: "pro", used: 535, limit: 1000, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
        h.shared.usage = cached
        h.billing.customerInfoError = Boom()
        h.usage.planSource = nil
        h.usage.snapshot = UsageSnapshot(plan: "unknown", used: 0, limit: 0, resetsAt: cached.resetsAt)
        let model = h.makeModel()

        await model.start()

        #expect(model.usage == UsageInfo(used: 535, limit: 1000, resetsAt: cached.resetsAt))
        #expect(model.plans.filter(\.isCurrent).map(\.name) == ["Pro"])
        #expect(h.shared.usage == cached)
    }

    /// Server contract (F3): a local ID is unknown to RevenueCat (401 unknown_user), so the app does
    /// not ask for usage with it; the Plan tab stays "unavailable" with no error.
    @Test func localUserIDDoesNotAskTheServerForUsage() async {
        let h = Harness()
        h.billing.appUserID = nil
        let model = h.makeModel()

        await model.start()
        await model.didBecomeActive()

        #expect(h.usage.calls.isEmpty)
        #expect(!model.plansAvailable)
    }

    /// An ID left by an earlier RevenueCat build is replaced by a local one.
    @Test func localUserIDReplacesAStaleRevenueCatID() {
        #expect(AppModel.localAppUserID(existing: "local:abc") == "local:abc")
        #expect(AppModel.localAppUserID(existing: "$RCAnonymousID:old").hasPrefix("local:"))
        #expect(AppModel.localAppUserID(existing: nil).hasPrefix("local:"))
    }

    @Test func withoutRevenueCatPlanTapsDoNothing() async {
        let h = Harness()
        h.billing.appUserID = nil
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "pro_monthly")
        await model.selectPlan(id: "free")

        #expect(h.billing.purchased.isEmpty)
        #expect(h.billing.manageSubscriptionsCalls == 0)
    }

    @Test func addAccountUnknownDomainAsksForServerSettings() async {
        let h = Harness()
        let model = h.makeModel()

        await #expect(throws: SkiPassUIError.needsServerSettings) {
            _ = try await model.addAccount(email: "info@myshop.jp")
        }
        #expect(h.accounts.signIns.isEmpty)
        #expect(h.accounts.mailboxes.isEmpty)
    }

    @Test func addGmailSignsInWithHintAndSavesPreset() async throws {
        let h = Harness()
        let model = h.makeModel()

        let account = try await model.addAccount(email: "hello@gmail.com")

        #expect(h.accounts.signIns.count == 1)
        #expect(h.accounts.signIns.first?.kind == .google)
        #expect(h.accounts.signIns.first?.loginHint == "hello@gmail.com")
        #expect(h.accounts.oauthStates[account.id] == Data("state".utf8))
        let saved = try #require(h.accounts.mailboxes.first)
        #expect(saved.id == account.id)
        #expect(saved.kind == .google)
        #expect(saved.imapHost == "imap.gmail.com")
        #expect(saved.imapPort == 993)
        #expect(saved.username == "hello@gmail.com")
        #expect(account.kind == .google)
        #expect(account.server == nil)
        #expect(model.accounts.map(\.id) == [account.id])
    }

    @Test func addOutlookUsesMicrosoftPreset() async throws {
        let h = Harness()
        let model = h.makeModel()

        _ = try await model.addAccount(email: "team@hotmail.com")

        let saved = try #require(h.accounts.mailboxes.first)
        #expect(saved.kind == .microsoft)
        #expect(saved.imapHost == "outlook.office365.com")
        #expect(saved.imapPort == 993)
    }

    @Test func mailboxUsesTheAddressThatSignedIn() async throws {
        let h = Harness()
        h.accounts.signedInAddress = "Real.Name@gmail.com"
        let model = h.makeModel()

        let account = try await model.addAccount(email: "realname@gmail.com")

        #expect(account.address == "Real.Name@gmail.com")
        #expect(h.accounts.mailboxes.first?.username == "Real.Name@gmail.com")
    }

    @Test func signingInAgainReusesTheMailbox() async throws {
        let h = Harness()
        let model = h.makeModel()

        let first = try await model.addAccount(email: "hello@gmail.com")
        let second = try await model.addAccount(email: "HELLO@gmail.com")

        #expect(second.id == first.id)
        #expect(h.accounts.mailboxes.count == 1)
    }

    @Test func missingClientIDDoesNotOpenProviderAndExplains() async {
        let h = Harness()
        h.accounts.unconfiguredKinds = [.google, .microsoft]
        let model = h.makeModel()

        await #expect(throws: SkiPassUIError.googleSignInNotConfigured) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        await #expect(throws: SkiPassUIError.microsoftSignInNotConfigured) {
            _ = try await model.addAccount(email: "team@outlook.com")
        }
        #expect(h.accounts.signIns.isEmpty)
        #expect(h.accounts.mailboxes.isEmpty)
    }

    @Test func missingClientIDDoesNotAffectIMAP() async {
        let h = Harness()
        h.accounts.unconfiguredKinds = [.google, .microsoft]
        let model = h.makeModel()

        await #expect(throws: SkiPassUIError.needsServerSettings) {
            _ = try await model.addAccount(email: "info@myshop.jp")
        }
    }

    @Test func failedSignInSavesNothing() async {
        let h = Harness()
        h.accounts.signInError = Boom()
        let model = h.makeModel()

        await #expect(throws: SkiPassUIError.signInFailed) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        #expect(h.accounts.mailboxes.isEmpty)
        #expect(h.accounts.oauthStates.isEmpty)
    }

    /// Cancelling the Google / Microsoft page (AppAuth -3) is silent: a CancellationError,
    /// which the sheet does not show.
    @Test func cancelledSignInIsSilent() async {
        let h = Harness()
        h.accounts.signInError = NSError(domain: "org.openid.appauth.general", code: -3)
        let model = h.makeModel()

        await #expect(throws: CancellationError.self) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        #expect(h.accounts.mailboxes.isEmpty)
    }

    /// A mailbox that switches from IMAP to Google loses its password, and back.
    @Test func changingKindDeletesTheOtherSecret() async throws {
        let h = Harness()
        let model = h.makeModel()
        let imap = try await model.saveIMAP(
            address: "me@gmail.com",
            settings: ServerSettings(incomingHost: "imap.gmail.com", incomingPort: 993, username: "me@gmail.com"),
            password: "pw")
        #expect(h.accounts.passwords[imap.id] == "pw")

        let google = try await model.addAccount(email: "me@gmail.com")
        #expect(google.id == imap.id)
        #expect(h.accounts.passwords[imap.id] == nil)
        #expect(h.accounts.oauthStates[imap.id] != nil)

        _ = try await model.saveIMAP(
            address: "me@gmail.com",
            settings: ServerSettings(incomingHost: "imap.gmail.com", incomingPort: 993, username: "me@gmail.com"),
            password: "pw2")
        #expect(h.accounts.oauthStates[imap.id] == nil)
        #expect(h.accounts.passwords[imap.id] == "pw2")
    }

    /// When the mailbox cannot be saved, no orphan secret stays and the UI gets a Copy error.
    @Test func failedMailboxSaveLeavesNoOrphanSecret() async {
        let h = Harness()
        h.accounts.saveMailboxError = Boom()
        let model = h.makeModel()

        await #expect(throws: SkiPassUIError.saveFailed) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        await #expect(throws: SkiPassUIError.saveFailed) {
            _ = try await model.saveIMAP(
                address: "info@myshop.jp",
                settings: ServerSettings(incomingHost: "h", incomingPort: 993, username: "u"),
                password: "pw")
        }
        #expect(h.accounts.oauthStates.isEmpty)
        #expect(h.accounts.passwords.isEmpty)
        #expect(h.accounts.mailboxes.isEmpty)
    }

    /// A storage error on delete reaches the UI as a Copy-backed error.
    @Test func failedDeleteReportsDeleteFailed() async throws {
        let h = Harness()
        let model = h.makeModel()
        let account = try await model.saveIMAP(
            address: "info@myshop.jp",
            settings: ServerSettings(incomingHost: "h", incomingPort: 993, username: "u"),
            password: "pw")
        h.accounts.deleteError = Boom()

        await #expect(throws: SkiPassUIError.deleteFailed) {
            try await model.deleteAccount(id: account.id)
        }
        #expect(model.accounts.map(\.id) == [account.id])
    }

    @Test func saveIMAPStoresPasswordAndConfigAndReusesIDOnEdit() async throws {
        let h = Harness()
        let model = h.makeModel()
        let settings = ServerSettings(incomingHost: "mail.myshop.jp", incomingPort: 993, username: "info@myshop.jp")

        let first = try await model.saveIMAP(address: "info@myshop.jp", settings: settings, password: "pw1")
        #expect(h.accounts.passwords[first.id] == "pw1")
        #expect(h.accounts.mailboxes.first?.imapHost == "mail.myshop.jp")
        #expect(first.server == settings)

        var edited = settings
        edited.incomingPort = 143
        let second = try await model.saveIMAP(address: "INFO@myshop.jp", settings: edited, password: "pw2")
        #expect(second.id == first.id)
        #expect(h.accounts.mailboxes.count == 1)
        #expect(h.accounts.mailboxes.first?.imapPort == 143)
        #expect(await model.revealPassword(id: first.id) == "pw2")
    }

    @Test func deleteRemovesCredentialsAndMailbox() async throws {
        let h = Harness()
        let model = h.makeModel()
        let account = try await model.saveIMAP(
            address: "info@myshop.jp",
            settings: ServerSettings(incomingHost: "h", incomingPort: 993, username: "u"),
            password: "pw")

        try await model.deleteAccount(id: account.id)

        #expect(h.accounts.deletedCredentials == [account.id])
        #expect(h.accounts.mailboxes.isEmpty)
        #expect(model.accounts.isEmpty)
        #expect(await model.revealPassword(id: account.id) == nil)
    }

    @Test func selectPlanPurchasesThenRefreshesPlansAndUsage() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.activeAfterPurchase = ["skipass_pro_monthly"]
        let model = h.makeModel()
        await model.start()
        #expect(h.usage.calls.count == 1)

        await model.selectPlan(id: "pro_monthly")

        #expect(h.billing.purchased == ["pro_monthly"])
        #expect(model.plans.first(where: \.isCurrent)?.id == "pro_monthly")
        #expect(h.usage.calls.count == 2)
    }

    @Test func cancelledPurchaseDoesNotRefresh() async {
        let h = Harness()
        h.billing.packages = [standard]
        h.billing.purchaseCompletes = false
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "$rc_monthly")

        #expect(h.billing.purchased == ["$rc_monthly"])
        #expect(h.usage.calls.count == 1)
    }

    @Test func tappingFreeDoesNotPurchase() async {
        let h = Harness()
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "free")

        #expect(h.billing.purchased.isEmpty)
    }

    @Test func upgradeStandardToProMakesProCurrentAndKeepsOtherRowsSelectable() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.addsPurchasedProduct = true
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "$rc_monthly")
        #expect(model.plans.first(where: \.isCurrent)?.id == "$rc_monthly")
        #expect(model.plans.filter { !$0.isCurrent }.map(\.id) == ["free", "pro_monthly"])

        await model.selectPlan(id: "pro_monthly")

        #expect(h.billing.purchased == ["$rc_monthly", "pro_monthly"])
        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])
        #expect(model.plans.filter { !$0.isCurrent }.map(\.id) == ["free", "$rc_monthly"])
    }

    @Test func downgradeProToStandardPurchasesButProStaysCurrentWhileActive() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.active = ["skipass_pro_monthly"]
        h.billing.addsPurchasedProduct = true
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "$rc_monthly")

        #expect(h.billing.purchased == ["$rc_monthly"])
        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])

        // Pro ends (Test Store: after its last renewal): the next foreground refresh shows Standard.
        h.billing.active = ["skipass_standard_monthly"]
        await model.didBecomeActive()
        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["$rc_monthly"])
    }

    @Test func freeRowOpensSubscriptionManagementWhenPaid() async {
        let h = Harness()
        h.billing.packages = [standard]
        h.billing.active = ["skipass_standard_monthly"]
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "free")

        #expect(h.billing.manageSubscriptionsCalls == 1)
        #expect(h.billing.purchased.isEmpty)

        // The subscription ended: Free becomes current on the next foreground refresh.
        h.billing.active = []
        await model.didBecomeActive()
        #expect(model.plans.filter(\.isCurrent).map(\.id) == ["free"])
    }

    @Test func freeRowDoesNothingWhenAlreadyFree() async {
        let h = Harness()
        h.billing.packages = [standard]
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "free")

        #expect(h.billing.manageSubscriptionsCalls == 0)
    }

    @Test func tapsWhileAPurchaseIsOpenAreIgnoredAndRowsWorkAfterwards() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.holdPurchases = true
        let model = h.makeModel()
        await model.start()

        let first = Task { await model.selectPlan(id: "pro_monthly") }
        while h.billing.heldCount == 0 { await Task.yield() }
        await model.selectPlan(id: "$rc_monthly")
        #expect(h.billing.purchased == ["pro_monthly"])

        h.billing.releasePurchases()
        await first.value
        h.billing.holdPurchases = false

        await model.selectPlan(id: "$rc_monthly")
        #expect(h.billing.purchased == ["pro_monthly", "$rc_monthly"])
    }

    @Test func failedPurchaseStillAllowsTheNextTap() async {
        let h = Harness()
        h.billing.packages = [standard, pro]
        h.billing.purchaseError = Boom()
        let model = h.makeModel()
        await model.start()

        await model.selectPlan(id: "pro_monthly")
        h.billing.purchaseError = nil
        await model.selectPlan(id: "pro_monthly")

        #expect(h.billing.purchased == ["pro_monthly", "pro_monthly"])
    }

    @Test func identitiesAreSyncedOnStartAddAndDelete() async throws {
        let h = Harness()
        let model = h.makeModel()

        await model.start()
        #expect(h.identities.syncs == [[]])

        let account = try await model.addAccount(email: "hello@gmail.com")
        #expect(h.identities.syncs.last == ["hello@gmail.com"])

        try await model.deleteAccount(id: account.id)
        #expect(h.identities.syncs.last == [])
        #expect(h.identities.syncs.count == 3)
    }

    /// Identity syncs run one at a time and each reads the mailbox list when it runs, so a
    /// sync started before a delete cannot finish last with the deleted address.
    @Test func identitySyncsAreSerializedAndTheNewestListWins() async throws {
        let h = Harness()
        let model = h.makeModel()
        await model.start()
        let account = try await model.addAccount(email: "hello@gmail.com")

        h.identities.hold = true
        let foreground = Task { await model.didBecomeActive() }
        while h.identities.heldCount == 0 { await Task.yield() }
        let delete = Task { try await model.deleteAccount(id: account.id) }
        for _ in 0..<50 { await Task.yield() }
        #expect(h.identities.heldCount == 1)  // the delete's sync waits for the running one
        h.identities.hold = false
        h.identities.release()
        await foreground.value
        try await delete.value

        #expect(h.identities.syncs.last == [])
    }

    /// A foreground event during launch does not start a second full refresh.
    @Test func foregroundDuringStartIsIgnored() async {
        let h = Harness()
        h.usage.hold = true
        let model = h.makeModel()

        let launch = Task { await model.start() }
        while h.usage.heldCount == 0 { await Task.yield() }
        await model.didBecomeActive()
        h.usage.hold = false
        h.usage.release()
        await launch.value

        #expect(h.usage.calls.count == 1)
        #expect(h.identities.syncs.count == 1)
    }

    /// A refresh requested while another is in flight is re-run afterwards, not dropped,
    /// so the post-purchase limit is shown.
    @Test func usageRefreshDuringAnInFlightOneIsNotDropped() async {
        let h = Harness()
        let model = h.makeModel()
        await model.start()
        h.usage.hold = true
        let before = h.usage.calls.count

        let foreground = Task { await model.refreshUsage() }
        while h.usage.heldCount == 0 { await Task.yield() }
        // The purchase completes: the server now reports the Pro limit.
        h.usage.snapshot = UsageSnapshot(plan: "pro", used: 3, limit: 1000, resetsAt: h.usage.snapshot.resetsAt)
        let afterPurchase = Task { await model.refreshUsage() }
        for _ in 0..<50 { await Task.yield() }
        h.usage.hold = false
        h.usage.release()
        await foreground.value
        await afterPurchase.value

        #expect(h.usage.calls.count == before + 2)
        #expect(model.usage?.limit == 1000)
    }

    @Test func foregroundRefreshesUsageAfterStart() async {
        let h = Harness()
        let model = h.makeModel()

        await model.didBecomeActive()
        #expect(h.usage.calls.isEmpty)

        await model.start()
        await model.didBecomeActive()
        #expect(h.usage.calls.count == 2)
    }
}
#endif
