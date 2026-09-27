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

    func loadMailboxes() throws -> [MailboxConfig] { mailboxes }

    func saveMailbox(_ mailbox: MailboxConfig) throws {
        if let index = mailboxes.firstIndex(where: { $0.id == mailbox.id }) {
            mailboxes[index] = mailbox
        } else {
            mailboxes.append(mailbox)
        }
    }

    func deleteMailbox(id: UUID) throws { mailboxes.removeAll { $0.id == id } }
    func savePassword(_ password: String, mailboxID: UUID) throws { passwords[mailboxID] = password }
    func password(mailboxID: UUID) -> String? { passwords[mailboxID] }

    func deleteCredentials(mailboxID: UUID) throws {
        deletedCredentials.append(mailboxID)
        passwords[mailboxID] = nil
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
    var active: Set<String> = []
    var purchased: [String] = []
    var purchaseCompletes = true
    var activeAfterPurchase: Set<String>?

    func configure() -> String? { appUserID }
    func currentPackages() async throws -> [StorePackageInfo] { packages }
    func activeEntitlementProductIDs() async throws -> Set<String> { active }

    func purchase(packageID: String) async throws -> Bool {
        purchased.append(packageID)
        if purchaseCompletes, let activeAfterPurchase { active = activeAfterPurchase }
        return purchaseCompletes
    }
}

@MainActor
private final class FakeUsage: UsageServices {
    var snapshot = UsageSnapshot(plan: "free", used: 3, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
    var calls: [String] = []
    var error: Error?

    func currentUsage(appUserID: String) async throws -> UsageSnapshot {
        calls.append(appUserID)
        if let error { throw error }
        return snapshot
    }
}

@MainActor
private final class FakeSharedState: SharedStateServices {
    var appUserID: String?
    var usage: UsageSnapshot?

    func setAppUserID(_ appUserID: String) { self.appUserID = appUserID }
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

    func makeModel() -> AppModel {
        AppModel(services: AppServicesBundle(accounts: accounts, billing: billing, usage: usage, sharedState: shared))
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
        #expect(account.server?.outgoingHost == nil)
        #expect(account.server?.outgoingPort == nil)
    }

    @Test func plansWithoutEntitlementMakeFreeCurrent() {
        let plans = AppModel.planOptions(packages: [pro, standard], activeProductIDs: [])
        #expect(plans.map(\.id) == ["free", "$rc_monthly", "pro_monthly"])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["free"])
        #expect(plans[1].name == "Standard")
        #expect(plans[1].tagline == "More fills")
        #expect(plans[1].priceText == "$2.99")
    }

    @Test func activeEntitlementMarksItsPackageCurrent() {
        let plans = AppModel.planOptions(packages: [standard, pro], activeProductIDs: ["skipass_pro_monthly"])
        #expect(plans.filter(\.isCurrent).map(\.id) == ["pro_monthly"])
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

        #expect(h.shared.appUserID == "$RCAnonymousID:test")
        #expect(model.accounts.map(\.address) == ["a@gmail.com"])
        #expect(model.plans.map(\.id) == ["free", "$rc_monthly"])
        #expect(h.usage.calls == ["$RCAnonymousID:test"])
        #expect(model.usage == UsageInfo(used: 3, limit: 10, resetsAt: h.usage.snapshot.resetsAt))
        #expect(h.shared.usage == h.usage.snapshot)
    }

    @Test func cachedUsageIsKeptWhenServerFails() async {
        let h = Harness()
        let cached = UsageSnapshot(plan: "free", used: 1, limit: 10, resetsAt: Date(timeIntervalSince1970: 1_700_000_000))
        h.shared.usage = cached
        h.usage.error = Boom()
        let model = h.makeModel()

        await model.start()

        #expect(model.usage == UsageInfo(used: 1, limit: 10, resetsAt: cached.resetsAt))
    }

    @Test func withoutBillingNoServerCallsAndFreeOnly() async {
        let h = Harness()
        h.billing.appUserID = nil
        let model = h.makeModel()

        await model.start()

        #expect(h.shared.appUserID == nil)
        #expect(h.usage.calls.isEmpty)
        #expect(model.plans.map(\.id) == ["free"])
        #expect(model.plans.first?.isCurrent == true)
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

        await #expect(throws: AppModelError.signInNotConfigured(.google)) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        await #expect(throws: AppModelError.signInNotConfigured(.microsoft)) {
            _ = try await model.addAccount(email: "team@outlook.com")
        }
        #expect(h.accounts.signIns.isEmpty)
        #expect(h.accounts.mailboxes.isEmpty)
        #expect(AppModelError.signInNotConfigured(.google).localizedDescription
            == "Google sign-in is not configured in this build.")
        #expect(AppModelError.signInNotConfigured(.microsoft).localizedDescription
            == "Microsoft sign-in is not configured in this build.")
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

        await #expect(throws: Boom.self) {
            _ = try await model.addAccount(email: "hello@gmail.com")
        }
        #expect(h.accounts.mailboxes.isEmpty)
        #expect(h.accounts.oauthStates.isEmpty)
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
