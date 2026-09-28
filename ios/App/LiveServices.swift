import AuthenticationServices
import Foundation
import SkiPassAuth
import SkiPassAuthUI
import SkiPassModels
import SkiPassServerClient
import SkiPassStorage
import RevenueCat
import UIKit
import os

// All concrete construction lives in this file.
//
// Symbols used from the SkiPassCore packages:
//   SkiPassStorage: MailboxStore(defaults:) list / add / update / remove(id:); KeychainStore.delete(account:)
//                   CredentialStore() setIMAPPassword / imapPassword / setOAuthStateData / removeAll(for:)
//                   AppGroupState(defaults:) revenueCatAppUserID / usageSnapshot() / setUsageSnapshot(_:) throws
//   SkiPassAuth:    OAuthService() (client IDs from Info.plist)
//   SkiPassAuthUI:  OAuthService.signIn (app-only split)
//                   .signIn(kind:presenting:loginHint:) async throws -> (address: String, authStateData: Data)
//   SkiPassServerClient: ServerClient(configuration: ServerClientConfiguration(baseURL:appToken:appUserID:))
//                   currentUsage() async throws -> UsageSnapshot

@MainActor
enum LiveServices {
    static func make(bundle: Bundle = .main) -> AppServicesBundle {
        let config = AppConfiguration(bundle: bundle)
        return AppServicesBundle(
            accounts: LiveAccountServices(),
            billing: LiveBillingServices(apiKey: config.revenueCatAPIKey),
            usage: LiveUsageServices(configuration: config),
            sharedState: LiveSharedStateServices(),
            identities: LiveIdentityServices(bundle: bundle)
        )
    }
}

/// Build-time values from Info.plist (docs/ARCHITECTURE.md §1).
struct AppConfiguration: Sendable {
    var serverURL: URL?
    var appToken: String?
    var revenueCatAPIKey: String?

    init(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    init(info: [String: Any]) {
        serverURL = Self.value("SkiPassServerURL", in: info).flatMap(URL.init(string:))
        appToken = Self.value("SkiPassAppToken", in: info)
        revenueCatAPIKey = Self.value("RevenueCatAPIKey", in: info)
    }

    /// Placeholders of `ios/Config/Secrets.example.xcconfig`, kept by builds made without the
    /// corresponding secret; they mean "not configured".
    static let exampleValues: Set<String> = [
        "https://skipass.example.invalid",
        "example-app-token",
        "appl_example",
    ]

    /// Non-empty, substituted Info.plist string that is not an example placeholder (an unset
    /// xcconfig variable leaves "" or "$(NAME)").
    private static func value(_ key: String, in info: [String: Any]) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$("), !exampleValues.contains(value) else { return nil }
        return value
    }
}

enum LiveServicesError: Error {
    case noPresentingViewController
    case packageNotFound(String)
}

// MARK: - Accounts (SkiPassStorage + SkiPassAuth)

@MainActor
final class LiveAccountServices: AccountServices {
    /// Runtime-resolved App Group defaults, or the app's own defaults when none is available.
    private let mailboxStore = MailboxStore(defaults: SharedStorageEnvironment.current.defaults)
    private let secrets: KeychainStore
    private let credentialStore: CredentialStore
    private let oauthService = OAuthService()

    init() {
        secrets = KeychainStore()
        credentialStore = CredentialStore(secrets: secrets)
    }

    func loadMailboxes() throws -> [MailboxConfig] {
        try mailboxStore.list()
    }

    func saveMailbox(_ mailbox: MailboxConfig) throws {
        if try mailboxStore.list().contains(where: { $0.id == mailbox.id }) {
            try mailboxStore.update(mailbox)
        } else {
            try mailboxStore.add(mailbox)
        }
    }

    func deleteMailbox(id: UUID) throws {
        try mailboxStore.remove(id: id)
    }

    func deletePassword(mailboxID: UUID) throws {
        try secrets.delete(account: StorageConstants.KeychainAccount.password(mailboxID))
    }

    func deleteOAuthState(mailboxID: UUID) throws {
        try secrets.delete(account: StorageConstants.KeychainAccount.oauth(mailboxID))
    }

    func savePassword(_ password: String, mailboxID: UUID) throws {
        try credentialStore.setIMAPPassword(password, for: mailboxID)
    }

    func password(mailboxID: UUID) -> String? {
        try? credentialStore.imapPassword(for: mailboxID)
    }

    func deleteCredentials(mailboxID: UUID) throws {
        try credentialStore.removeAll(for: mailboxID)
    }

    func isSignInConfigured(kind: ProviderKind) -> Bool {
        oauthService.clients.isConfigured(kind)
    }

    func signIn(kind: ProviderKind, loginHint: String) async throws -> OAuthSignInResult {
        guard let presenter = Self.topViewController() else {
            throw LiveServicesError.noPresentingViewController
        }
        let result = try await oauthService.signIn(kind: kind, presenting: presenter, loginHint: loginHint)
        return OAuthSignInResult(address: result.address, authStateData: result.authStateData)
    }

    func saveOAuthState(_ data: Data, mailboxID: UUID) throws {
        try credentialStore.setOAuthStateData(data, for: mailboxID)
    }

    /// The front-most view controller of the active window scene (the add-account sheet while it is open).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - Billing (RevenueCat purchases-ios)

@MainActor
final class LiveBillingServices: BillingServices {
    private let apiKey: String?
    /// Packages from the last fetch, by `Package.identifier`, so a tapped plan can be purchased.
    private var packagesByID: [String: Package] = [:]

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func configure() -> String? {
        guard let apiKey else { return nil }
        if !Purchases.isConfigured {
            // Anonymous user: RevenueCat generates and caches a `$RCAnonymousID:` app user ID.
            Purchases.configure(withAPIKey: apiKey, appUserID: nil)
        }
        return Purchases.shared.appUserID
    }

    func currentPackages() async throws -> [StorePackageInfo] {
        let offerings = try await Purchases.shared.offerings()
        let packages = offerings.current?.availablePackages ?? []
        packagesByID = Dictionary(packages.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        return packages.map { package in
            StorePackageInfo(
                id: package.identifier,
                productID: package.storeProduct.productIdentifier,
                title: package.storeProduct.localizedTitle,
                description: package.storeProduct.localizedDescription,
                priceString: package.storeProduct.localizedPriceString,
                price: package.storeProduct.price
            )
        }
    }

    func entitlements() async throws -> EntitlementSnapshot {
        let entitlements = try await Purchases.shared.customerInfo().entitlements
        return EntitlementSnapshot(
            active: Set(entitlements.active.keys),
            productIDs: entitlements.all.mapValues(\.productIdentifier)
        )
    }

    func purchase(packageID: String) async throws -> Bool {
        guard let package = packagesByID[packageID] else {
            throw LiveServicesError.packageNotFound(packageID)
        }
        let result = try await Purchases.shared.purchase(package: package)
        return !result.userCancelled
    }

    /// purchases-ios 5.91.0 `Purchases.showManageSubscriptions()` (Purchases.swift:1652) ->
    /// `ManageSubscriptionsHelper.showManageSubscriptions` (Support/ManageSubscriptionsHelper.swift:34-65):
    /// opens `CustomerInfo.managementURL`, or Apple's subscription sheet
    /// (`AppStore.showManageSubscriptions(in:)`) when that URL is nil or an Apple URL.
    ///
    /// Test Store limitation: the SDK has no Test Store cancellation. Customer Center offers
    /// "cancel" for a non-App-Store purchase only when it has a `managementURL`
    /// (RevenueCatUI/CustomerCenter/Actions/CustomerCenterConfigData.HelpPath+PurchaseInformation.swift:50-53),
    /// and Apple's sheet lists App Store subscriptions only. Test Store subscriptions renew at most
    /// five times and then end with their entitlements (RevenueCat docs, "RevenueCat Test Store").
    func showManageSubscriptions() async throws {
        try await Purchases.shared.showManageSubscriptions()
    }
}

// MARK: - Usage (SkiPassServerClient)

@MainActor
final class LiveUsageServices: UsageServices {
    private let configuration: AppConfiguration

    init(configuration: AppConfiguration) {
        self.configuration = configuration
    }

    func currentUsage(appUserID: String) async throws -> UsageSnapshot {
        guard let baseURL = configuration.serverURL, let appToken = configuration.appToken else {
            throw URLError(.badURL)
        }
        let client = ServerClient(configuration: ServerClientConfiguration(
            baseURL: baseURL,
            appToken: appToken,
            appUserID: { appUserID }
        ))
        return try await client.currentUsage()
    }
}

// MARK: - One-time-code identities (ios/Extension/Identity, compiled into the app too)

@MainActor
final class LiveIdentityServices: IdentityServices {
    private let bundle: Bundle
    private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "Identities")

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func syncIdentities(mailboxAddresses: [String]) async {
        let seen = SeenDomainStore(defaults: SharedStorageEnvironment.current.defaults)
        let registrar = IdentityRegistrar(domainSource: CompositeDomainSource.standard(bundle: bundle, seen: seen))
        let result = await registrar.register(mailboxAddresses: mailboxAddresses)
        logger.notice("Identity sync: \(String(describing: result), privacy: .public)")
    }
}

// MARK: - App Group state (SkiPassStorage)

@MainActor
final class LiveSharedStateServices: SharedStateServices {
    private let state = AppGroupState(defaults: SharedStorageEnvironment.current.defaults)
    private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "AppGroupState")

    func appUserID() -> String? {
        state.revenueCatAppUserID
    }

    func setAppUserID(_ appUserID: String) {
        state.revenueCatAppUserID = appUserID
    }

    func cachedUsage() -> UsageSnapshot? {
        state.usageSnapshot()
    }

    func cacheUsage(_ snapshot: UsageSnapshot) {
        do {
            try state.setUsageSnapshot(snapshot)
        } catch {
            logger.error("Caching usage failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - AutoFill settings (AuthenticationServices)

/// Apple documentation (developer.apple.com/documentation/authenticationservices/...):
/// - `ascredentialidentitystore/getstate(_:)` (iOS 12+): "Gets the state of the credential identity
///   store"; `ascredentialidentitystorestate/isenabled`: whether the store is enabled.
/// - `assettingshelper/requesttoturnoncredentialproviderextension(completionhandler:)` (iOS 18+):
///   "If the extension is not currently enabled, a prompt will be shown to allow it to be turned on.
///   The completion handler is called with YES or NO depending on whether the credential provider is
///   enabled. You need to wait 10 seconds in order to make additional request to this API."
///   The 10 s wait is enforced by `AutoFillSetupModel`.
/// - `assettingshelper/opencredentialproviderappsettings(completionhandler:)` (iOS 17+): "Open the
///   Settings app and navigate to the AutoFill provider settings."
/// Completion-handler forms, as in `IdentityRegistrar`, so nothing non-Sendable crosses actors.
@MainActor
final class LiveAutoFillSettings: AutoFillSettingsServices {
    func isExtensionEnabled() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASCredentialIdentityStore.shared.getState { state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    func requestToTurnOnExtension() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASSettingsHelper.requestToTurnOnCredentialProviderExtension { enabled in
                continuation.resume(returning: enabled)
            }
        }
    }

    func openCredentialProviderSettings() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ASSettingsHelper.openCredentialProviderAppSettings { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
