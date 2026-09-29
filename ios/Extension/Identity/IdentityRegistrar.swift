import AuthenticationServices
import Foundation
import SkiPassModels

/// Supplies the site domains for which one-time-code identities are registered (docs/ARCHITECTURE.md §3 step 6).
/// Concrete sources: `DomainSources.swift` (bundled popular domains, demo site, domains seen in
/// verification emails).
protocol IdentityDomainSource: Sendable {
    func domains() async -> [String]
}

/// Registers `ASOneTimeCodeCredentialIdentity` entries so that iOS offers SkiPass in
/// one-time-code fields of matching sites (docs/ARCHITECTURE.md §3 step 6: background, no UI).
/// Compiled into both the app (launch, mailbox added/removed) and the extension (each run).
struct IdentityRegistrar: Sendable {
    let domainSource: any IdentityDomainSource

    enum Result: Sendable, Equatable {
        case registered(count: Int)
        case removedAll
        case storeDisabled
        /// The identity store refused the write; `error` is its reason when it gave one.
        case failed(error: String?)

        /// The diagnostics record of this result (shown in the app's Diagnostics section).
        func record(process: String, at date: Date) -> RegistrationRecord {
            switch self {
            case .registered(let count):
                return RegistrationRecord(process: process, at: date, outcome: "registered", count: count, storeEnabled: true)
            case .removedAll:
                return RegistrationRecord(process: process, at: date, outcome: "removedAll", count: 0, storeEnabled: true,
                                          detail: "no mailbox")
            case .storeDisabled:
                return RegistrationRecord(process: process, at: date, outcome: "storeDisabled", storeEnabled: false,
                                          detail: "SkiPass is not turned on in AutoFill settings")
            case .failed(let error):
                return RegistrationRecord(process: process, at: date, outcome: "failed", storeEnabled: true, detail: error)
            }
        }
    }

    /// The identities for `domains` and `mailboxAddresses`; empty when there is no mailbox
    /// (nothing could be filled).
    static func identities(domains: [String], mailboxAddresses: [String]) -> [ASOneTimeCodeCredentialIdentity] {
        guard let label = label(mailboxAddresses: mailboxAddresses) else { return [] }
        return normalized(domains).map { domain in
            ASOneTimeCodeCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
                label: label,
                recordIdentifier: Self.recordIdentifier(domain: domain)
            )
        }
    }

    /// Makes the store hold exactly one identity per domain for the given mailbox addresses,
    /// or none when there is no mailbox.
    ///
    /// The whole set is written with `replaceCredentialIdentities` because the label depends on the
    /// mailboxes and domains can disappear; Apple recommends the incremental methods only "to avoid
    /// rewriting the entire store every time you need to make a change", and documents no size
    /// limit for the store (https://developer.apple.com/documentation/authenticationservices/ascredentialidentitystore).
    func register(mailboxAddresses: [String]) async -> Result {
        let domains = mailboxAddresses.isEmpty ? [] : await domainSource.domains()
        let identities = Self.identities(domains: domains, mailboxAddresses: mailboxAddresses)
        // "When the user disables your extension, the system clears and disables your shared store."
        guard await Self.storeIsEnabled() else { return .storeDisabled }
        if identities.isEmpty {
            let removed = await Self.removeAll()
            return removed.ok ? .removedAll : .failed(error: removed.error)
        }
        let all = identities.map { $0 as any ASCredentialIdentity }
        let replaced = await Self.replace(all)
        return replaced.ok ? .registered(count: all.count) : .failed(error: replaced.error)
    }

    /// The QuickType label for an identity (docs/ARCHITECTURE.md §3: `From <mailbox address>`).
    // Note: with several registered mailboxes the label names the first address only (one
    // identity per domain); a suggestion per mailbox would need one identity per domain and mailbox.
    static func label(mailboxAddresses: [String]) -> String? {
        guard let first = mailboxAddresses.first else { return nil }
        return "From \(first)"
    }

    static func recordIdentifier(domain: String) -> String {
        "otp.\(domain)"
    }

    /// Lowercased hosts, plausible domains only, without duplicates, sorted.
    static func normalized(_ domains: [String]) -> [String] {
        let hosts = domains.compactMap(EmailDomains.hostname).filter(EmailDomains.isPlausibleDomain)
        return Array(Set(hosts)).sorted()
    }

    // MARK: - ASCredentialIdentityStore

    private static func storeIsEnabled() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASCredentialIdentityStore.shared.getState { state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    /// Store write outcome; `error` summarizes the store's error (no identities in it).
    private struct WriteResult: Sendable {
        var ok: Bool
        var error: String?
    }

    private static func replace(_ identities: [any ASCredentialIdentity]) async -> WriteResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<WriteResult, Never>) in
            ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { ok, error in
                continuation.resume(returning: WriteResult(ok: ok, error: error.map { Diagnostics.errorSummary($0) }))
            }
        }
    }

    private static func removeAll() async -> WriteResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<WriteResult, Never>) in
            ASCredentialIdentityStore.shared.removeAllCredentialIdentities { ok, error in
                continuation.resume(returning: WriteResult(ok: ok, error: error.map { Diagnostics.errorSummary($0) }))
            }
        }
    }
}
