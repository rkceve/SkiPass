import Foundation

/// Mock data matching the original Home and Plan screen designs (fictional `.example` addresses
/// for custom domains). Previews only; no live services.
enum PreviewData {
    // MARK: Accounts (screen 1)

    static let infoAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let supportAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let gmailAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let outlookAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let salesAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    static let infoAccount = MailAccount(
        id: infoAccountID,
        address: "info@myshop.example",
        kind: .imap,
        status: .connected,
        server: ServerSettings(
            incomingHost: "mail.myshop.example",
            incomingPort: 993,
            username: "info@myshop.example"
        )
    )

    static let supportAccount = MailAccount(
        id: supportAccountID,
        address: "support@myshop.example",
        kind: .imap,
        status: .connected,
        server: ServerSettings(
            incomingHost: "mail.myshop.example",
            incomingPort: 993,
            username: "support@myshop.example"
        )
    )

    static let gmailAccount = MailAccount(
        id: gmailAccountID,
        address: "hello@gmail.com",
        kind: .google,
        status: .connected
    )

    static let outlookAccount = MailAccount(
        id: outlookAccountID,
        address: "team@outlook.com",
        kind: .microsoft,
        status: .connected
    )

    static let salesAccount = MailAccount(
        id: salesAccountID,
        address: "sales@studio.example",
        kind: .imap,
        status: .connected,
        server: ServerSettings(
            incomingHost: "imap.studio.example",
            incomingPort: 993,
            username: "sales@studio.example"
        )
    )

    static let accounts: [MailAccount] = [infoAccount, supportAccount, gmailAccount, outlookAccount, salesAccount]

    // MARK: Plans (screen 2)

    static let freePlan = PlanOption.free(isCurrent: false)

    static let standardPlan = PlanOption(
        id: "standard",
        name: "Standard",
        tagline: "For growing projects and teams.",
        priceText: "",  // not shown in the mockup
        isCurrent: true,
        systemImage: "square.stack.3d.up.fill"
    )

    static let proPlan = PlanOption(
        id: "pro",
        name: "Pro",
        tagline: "Higher limits for power users.",
        priceText: "$24.99/mo",
        isCurrent: false,
        systemImage: "crown.fill"
    )

    static let plans: [PlanOption] = [standardPlan, freePlan, proPlan]

    /// Nov 30, 2024: 12 days before the mockup's reset date.
    static let referenceDate = date(year: 2024, month: 11, day: 30)

    /// 535 used of 1,000 -> "465 of 1,000 left", resets Dec 12, 2024.
    static let usage = UsageInfo(used: 535, limit: 1_000, resetsAt: date(year: 2024, month: 12, day: 12))

    // MARK: Store

    @MainActor
    static func makeStore(expanded: UUID? = nil, usage: UsageInfo? = PreviewData.usage) -> SkiPassUIStore {
        let store = SkiPassUIStore(
            accounts: accounts,
            plans: plans,
            usage: usage,
            actions: PreviewActions(),
            referenceDate: referenceDate
        )
        store.expandedAccountID = expanded
        return store
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }
}

/// Preview-only actions. gmail.com / outlook.com addresses "sign in" immediately;
/// anything else asks for IMAP server settings.
@MainActor
final class PreviewActions: SkiPassUIActions {
    func addAccount(email: String) async throws -> MailAccount {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        switch domain {
        case "gmail.com":
            return MailAccount(address: email, kind: .google, status: .connected)
        case "outlook.com":
            return MailAccount(address: email, kind: .microsoft, status: .connected)
        default:
            throw SkiPassUIError.needsServerSettings
        }
    }

    func saveIMAP(address: String, settings: ServerSettings, password: String) async throws -> MailAccount {
        MailAccount(address: address, kind: .imap, status: .connected, server: settings)
    }

    func deleteAccount(id: UUID) async throws {}

    func revealPassword(id: UUID) async -> String? { "preview-password" }

    func selectPlan(id: String) async {}
}
