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
// Symbols used from packages written in parallel (read from origin/wip/i2 b76d60d and origin/wip/i5 7a8a6bc):
//   SkiPassStorage: MailboxStore() throws / list / add / update / remove(id:)
//                   CredentialStore() setIMAPPassword / imapPassword / setOAuthStateData / removeAll(for:)
//                   AppGroupState() throws  revenueCatAppUserID / usageSnapshot() / setUsageSnapshot(_:) throws
//   SkiPassAuth:    OAuthService() (client IDs from Info.plist)
//   SkiPassAuthUI:  OAuthService.signIn (app-only split, CONTRACTS §8 2026-09-24)
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
            sharedState: LiveSharedStateServices()
        )
    }
}

/// Build-time values from Info.plist (CONTRACTS §2).
struct AppConfiguration: Sendable {
    var serverURL: URL?
    var appToken: String?
    var revenueCatAPIKey: String?

    init(bundle: Bundle) {
        serverURL = Self.value("SkiPassServerURL", in: bundle).flatMap(URL.init(string:))
        appToken = Self.value("SkiPassAppToken", in: bundle)
        revenueCatAPIKey = Self.value("RevenueCatAPIKey", in: bundle)
    }

    /// Non-empty, substituted Info.plist string (an unset xcconfig variable leaves "" or "$(NAME)").
    private static func value(_ key: String, in bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
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
    private let mailboxStore: MailboxStore?
    private let credentialStore = CredentialStore()
    private let oauthService = OAuthService()

    init() {
        mailboxStore = try? MailboxStore()
    }

    private func store() throws -> MailboxStore {
        guard let mailboxStore else { throw StorageError.appGroupUnavailable }
        return mailboxStore
    }

    func loadMailboxes() throws -> [MailboxConfig] {
        try store().list()
    }

    func saveMailbox(_ mailbox: MailboxConfig) throws {
        let mailboxes = try store()
        if try mailboxes.list().contains(where: { $0.id == mailbox.id }) {
            try mailboxes.update(mailbox)
        } else {
            try mailboxes.add(mailbox)
        }
    }

    func deleteMailbox(id: UUID) throws {
        try store().remove(id: id)
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

    func activeEntitlementProductIDs() async throws -> Set<String> {
        let customerInfo = try await Purchases.shared.customerInfo()
        return Set(customerInfo.entitlements.active.values.map(\.productIdentifier))
    }

    func purchase(packageID: String) async throws -> Bool {
        guard let package = packagesByID[packageID] else {
            throw LiveServicesError.packageNotFound(packageID)
        }
        let result = try await Purchases.shared.purchase(package: package)
        return !result.userCancelled
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

// MARK: - App Group state (SkiPassStorage)

@MainActor
final class LiveSharedStateServices: SharedStateServices {
    private let state = try? AppGroupState()
    private let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "AppGroupState")

    func setAppUserID(_ appUserID: String) {
        state?.revenueCatAppUserID = appUserID
    }

    func cachedUsage() -> UsageSnapshot? {
        state?.usageSnapshot()
    }

    func cacheUsage(_ snapshot: UsageSnapshot) {
        do {
            try state?.setUsageSnapshot(snapshot)
        } catch {
            logger.error("Caching usage failed: \(String(describing: error), privacy: .public)")
        }
    }
}
