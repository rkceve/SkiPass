import Foundation

/// Every user-visible string of the app (SYSTEM.md §2). Strings marked "mockup" are copied
/// verbatim from design/screen1-accounts.png or design/screen2-plan.png. The host app reaches
/// the few it needs through public API (`PlanOption.free`, `PlanOption.paidPlanName`,
/// `SkiPassUIError`), so all copy stays in this one file.
enum Copy {
    // MARK: Header (mockup)
    static let appName = "SkiPass"
    static let appSubtitle = "Manage email accounts across domains."

    // MARK: Tabs (mockup)
    static let tabHome = "Home"
    static let tabPlan = "Plan"

    // MARK: Accounts screen (mockup)
    static let accountsTitle = "Accounts"
    static let add = "Add"
    static let kindCustomDomain = "Custom domain"
    static let kindGoogle = "Google"
    static let kindMicrosoft = "Microsoft"
    static let incomingServer = "Incoming Server"
    static let incomingPort = "Incoming Port"
    static let username = "Username"
    static let password = "Password"
    static let chipIMAP = "IMAP"
    static let edit = "Edit"
    static let delete = "Delete"
    static let passwordMask = "••••••••••••"

    // MARK: Accounts screen (not in mockups)
    static let addAccountLabel = "Add account"  // accessibility only
    static let showPassword = "Show password"  // accessibility only
    static let hidePassword = "Hide password"  // accessibility only
    static let expandAccount = "Show details"  // accessibility only
    static let collapseAccount = "Hide details"  // accessibility only
    static let statusConnected = "Connected"  // accessibility only
    static let deleteConfirmTitle = "Delete this account?"
    static let cancel = "Cancel"
    static let ok = "OK"
    static let errorTitle = "Something went wrong"
    static let errorTryAgain = "Please try again."  // not in mockups
    static let googleSignInNotConfigured = "Google sign-in is not configured in this build."
    static let microsoftSignInNotConfigured = "Microsoft sign-in is not configured in this build."
    static let signInFailed = "Couldn't sign in. Please try again."
    static let saveFailed = "Couldn't save this account. Please try again."
    static let deleteFailed = "Couldn't delete this account. Please try again."

    // MARK: Add / edit sheet (not in mockups)
    static let addAccountTitle = "Add Account"
    static let editAccountTitle = "Edit Account"
    static let emailAddress = "Email address"
    static let emailPlaceholder = "name@example.com"
    static let emailHelper = "Gmail and Outlook open their official sign-in. Other providers ask for server settings."
    static let emailInvalid = "Enter a valid email address, like name@example.com."
    static let clearEmail = "Clear email address"  // accessibility only
    static let continueAction = "Continue"
    static let save = "Save"
    static let serverSettingsSection = "Server settings"
    static let host = "Host"
    static let port = "Port"
    static let defaultIMAPPort = "993"

    // MARK: Plan screen (mockup)
    static let planTitle = "Plan"
    static let currentChip = "Current"
    static let remainingSends = "Remaining sends"  // [Open] one count = one code fill
    static let otherPlansTitle = "Other plans"
    static let plansUnavailable = "Plans are unavailable in this build."  // not in mockups

    // MARK: Plan names (mockup)
    static let freePlanName = "Free"
    static let freePlanTagline = "A simple start for personal use."
    static let freePlanPrice = "$0/mo"
    static let standardPlanName = "Standard"
    static let proPlanName = "Pro"

    static func remainingOfLimit(_ remaining: String, _ limit: String) -> String {
        "\(remaining) of \(limit) left"
    }

    static func resetsIn(days: Int) -> String {
        switch days {
        case ...0: "Resets today"  // not in mockups
        case 1: "Resets in 1 day"  // not in mockups
        default: "Resets in \(days) days"
        }
    }

    /// Message for an error thrown by the host app; nil when nothing should be shown
    /// (the user cancelled, e.g. closed the provider's sign-in page).
    static func errorMessage(for error: any Error) -> String? {
        if error is CancellationError { return nil }
        switch error as? SkiPassUIError {
        case .googleSignInNotConfigured: return googleSignInNotConfigured
        case .microsoftSignInNotConfigured: return microsoftSignInNotConfigured
        case .signInFailed: return signInFailed
        case .saveFailed: return saveFailed
        case .deleteFailed: return deleteFailed
        case .needsServerSettings, nil: return errorTryAgain
        }
    }
}
