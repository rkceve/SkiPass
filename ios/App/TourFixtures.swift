// Test fixture for the UI tour recording and the store screenshots (ios/UITests); not a feature.
// Compiled only into Debug builds. Launching with `-SkiPassTourFixtures` replaces the live
// services (storage, OAuth, RevenueCat, server) with in-memory data: no accounts, keychain or
// network. All addresses use the reserved `.example` TLD (RFC 2606).
#if DEBUG
import Foundation
import Observation
import SkiPassModels
import SkiPassUI

enum TourFixtures {
    static let launchArgument = "-SkiPassTourFixtures"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

/// In-memory stand-in for `AppModel` during the tour. The IMAP accounts and plans mirror
/// `SkiPassUI`'s internal `PreviewData` (which the app target cannot import); OAuth accounts are
/// left out so no provider names appear on screen.
@MainActor
@Observable
final class TourFixtureModel: SkiPassUIActions {
    private(set) var accounts: [MailAccount]
    private(set) var plans: [PlanOption]
    private(set) var usage: UsageInfo?
    @ObservationIgnored private var passwords: [UUID: String]

    init(now: Date = .now) {
        let info = MailAccount(
            address: "info@myshop.example",
            kind: .imap,
            status: .connected,
            server: ServerSettings(
                incomingHost: "mail.myshop.example",
                incomingPort: 993,
                username: "info@myshop.example"
            )
        )
        let support = MailAccount(
            address: "help@myshop.example",
            kind: .imap,
            status: .connected,
            server: ServerSettings(
                incomingHost: "mail.myshop.example",
                incomingPort: 993,
                username: "help@myshop.example"
            )
        )
        let sales = MailAccount(
            address: "sales@studio.example",
            kind: .imap,
            status: .connected,
            server: ServerSettings(
                incomingHost: "imap.studio.example",
                incomingPort: 993,
                username: "sales@studio.example"
            )
        )
        accounts = [info, support, sales]
        passwords = [info.id: "tour-fixture-1", support.id: "tour-fixture-2", sales.id: "tour-fixture-3"]

        plans = [
            PlanOption(
                id: "standard",
                name: "Standard",
                tagline: "For growing projects and teams.",
                priceText: "",
                isCurrent: true,
                systemImage: "square.stack.3d.up.fill"
            ),
            PlanOption.free(isCurrent: false),
            PlanOption(
                id: "pro",
                name: "Pro",
                tagline: "Higher limits for power users.",
                priceText: "$24.99/mo",
                isCurrent: false,
                systemImage: "crown.fill"
            ),
        ]

        // "465 of 1,000 left", resetting in 12 days.
        let calendar = Calendar.current
        let resetsAt = calendar.date(byAdding: .day, value: 12, to: calendar.startOfDay(for: now))
            .flatMap { calendar.date(byAdding: .hour, value: 12, to: $0) } ?? now
        usage = UsageInfo(used: 535, limit: 1_000, resetsAt: resetsAt)
    }

    // MARK: SkiPassUIActions (in memory)

    func addAccount(email: String) async throws -> MailAccount {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same routing as AppModel, but OAuth providers "sign in" instantly without a web page.
        switch AppModel.oauthProvider(forEmail: address) {
        case .google:
            return insert(MailAccount(address: address, kind: .google, status: .connected))
        case .microsoft:
            return insert(MailAccount(address: address, kind: .microsoft, status: .connected))
        default:
            throw SkiPassUIError.needsServerSettings
        }
    }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        let existing = accounts.first { $0.address.caseInsensitiveCompare(address) == .orderedSame }
        let account = MailAccount(
            id: existing?.id ?? UUID(),
            address: address,
            kind: .imap,
            status: .connected,
            server: settings
        )
        passwords[account.id] = password
        return insert(account)
    }

    func deleteAccount(id: UUID) async throws {
        accounts.removeAll { $0.id == id }
        passwords[id] = nil
    }

    func revealPassword(id: UUID) async -> String? {
        passwords[id]
    }

    func selectPlan(id: String) async {}

    private func insert(_ account: MailAccount) -> MailAccount {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        return account
    }
}
#endif
