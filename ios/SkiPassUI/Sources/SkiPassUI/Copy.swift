import Foundation

/// Every user-visible string of the app (docs/ARCHITECTURE.md §2). Strings marked "mockup" are copied
/// verbatim from the original screen designs (Home and Plan). The host app reaches
/// the few it needs through public API (`PlanOption.free`, `PlanOption.paidPlanName`,
/// `SkiPassUIError`), so all copy stays in this one file.
enum Copy {
    // MARK: Header (mockup)
    static let appName = "SkiPass"
    static let appSubtitle = "One-time codes from any inbox."

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
    static let remainingFills = "Remaining fills"  // one count = one code filled
    static let otherPlansTitle = "Other plans"
    static let plansUnavailable = "Plans are unavailable in this build."  // not in mockups

    // MARK: Plan names (mockup)
    static let freePlanName = "Free"
    static let freePlanTagline = "A few codes a month."
    static let freePlanPrice = "$0/mo"
    static let standardPlanName = "Standard"
    static let proPlanName = "Pro"
    // Taglines by plan tier, shown instead of the store product descriptions.
    static let standardPlanTagline = "For everyday sign-ins."
    static let proPlanTagline = "For heavy daily use."

    // MARK: Turn-on-AutoFill card (Home) and setup controls (not in mockups)
    static let autoFillCardTitle = "Turn on AutoFill"
    static let autoFillCardBody = "Codes appear above the keyboard only after you turn on SkiPass in AutoFill."
    static let autoFillTurnOn = "Turn On"
    static let autoFillOpenSettings = "Open Settings"
    static let autoFillIsOn = "AutoFill is on"

    // MARK: Information sheet (not in mockups)
    static let infoLabel = "How SkiPass works"  // accessibility label of the header (i) button
    static let infoTitle = "How SkiPass works"
    static let done = "Done"

    static let infoSetupTitle = "Setup"
    static let infoSetupAddMailbox = "Add a mailbox on the Home tab."
    static let infoSetupTurnOnAutoFill = "Turn on AutoFill for SkiPass."
    static let infoSetupOpenSite = "Open a site and tap its one-time code field."
    static let infoSetupTapSuggestion = "Tap the SkiPass suggestion above the keyboard."

    static let infoChoiceTitle = "How the right code is chosen"
    static let infoChoiceLines = [
        "SkiPass looks only at emails from the last 10 minutes in your inbox and junk/spam folder.",
        "Codes are found on your device.",
        "Jev then picks the email that belongs to the site you are on.",
        "If the SkiPass server can't be reached, the newest email that mentions the site is used, or else the newest email.",
    ]

    static let infoPrivacyTitle = "Privacy"
    static let infoPrivacyLines = [
        "Mail is read only when you tap the suggestion.",
        "Only emails from the last 10 minutes that contain a code are sent to the SkiPass server and Jev to be judged, with the site's address.",
        "The SkiPass server never stores or logs their text.",
        "Passwords and sign-in tokens stay in the Keychain on this device.",
        "Messages are never marked as read or moved.",
    ]

    static let infoPlansTitle = "Plans"
    static let infoPlansLines = [
        "Each code SkiPass fills uses one fill from your monthly allowance. Lookups that fill nothing are free.",
        "Your plan and the fills left this month are on the Plan tab.",
    ]

    static let infoVersionTitle = "Version"
    static let infoVersionUnknown = "Unknown"

    static let infoDiagnosticsTitle = "Diagnostics"
    static let diagnosticsIntro = "What happened the last times SkiPass was asked for a code on this device. No email text, codes, passwords or tokens are kept."
    static let diagnosticsBundleID = "App bundle ID"
    static let diagnosticsAppGroup = "App Group (app)"
    static let diagnosticsKeychainGroup = "Keychain group (app)"
    static let diagnosticsRegistrationApp = "Identity registration (app)"
    static let diagnosticsRegistrationExtension = "Identity registration (AutoFill)"
    static let diagnosticsNone = "none"
    static let diagnosticsDefaultGroup = "default (not shared)"
    static let diagnosticsNotYet = "not yet"
    static let diagnosticsRequestsTitle = "Last AutoFill requests"
    static let diagnosticsNoRequests = "No AutoFill request has reached SkiPass yet"
    static let diagnosticsNoRequestsHint = "If you already tapped the SkiPass suggestion in a code field, the AutoFill extension did not run, or it runs without sharing storage with this app."
    static let diagnosticsCopy = "Copy diagnostics"
    static let diagnosticsCopied = "Copied"
    static let diagnosticsTextHeader = "SkiPass diagnostics"

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

    /// "0.1.6 (42)": marketing version and build number.
    static func versionText(version: String, build: String) -> String {
        "\(version) (\(build))"
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
