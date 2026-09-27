import AuthenticationServices
import Foundation

/// Supplies the site domains for which one-time-code identities are registered (CONTRACTS §6 step 5).
/// Concrete sources: `DomainSources.swift` (bundled popular domains, demo site, domains seen in
/// verification emails).
protocol IdentityDomainSource: Sendable {
    func domains() async -> [String]
}

/// Registers `ASOneTimeCodeCredentialIdentity` entries so that iOS offers SkiPass in
/// one-time-code fields of matching sites (spec §6a: background, no UI).
/// Compiled into both the app (launch, mailbox added/removed) and the extension (each run).
struct IdentityRegistrar: Sendable {
    let domainSource: any IdentityDomainSource

    enum Result: Sendable, Equatable {
        case registered(count: Int)
        case removedAll
        case storeDisabled
        case failed
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
            return await Self.removeAll() ? .removedAll : .failed
        }
        let all = identities.map { $0 as any ASCredentialIdentity }
        return await Self.replace(all) ? .registered(count: all.count) : .failed
    }

    /// The QuickType label for an identity (CONTRACTS §6: `From <mailbox address>`).
    // OPEN(label): labelling with several registered mailboxes is undecided (spec §11.3:
    // one suggestion per mailbox, or one per site). Until decided, the first address is used.
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

    // MARK: - ASCredentialIdentityStore (docs/facts/F1 §1)

    private static func storeIsEnabled() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASCredentialIdentityStore.shared.getState { state in
                continuation.resume(returning: state.isEnabled)
            }
        }
    }

    private static func replace(_ identities: [any ASCredentialIdentity]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }

    private static func removeAll() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ASCredentialIdentityStore.shared.removeAllCredentialIdentities { ok, _ in
                continuation.resume(returning: ok)
            }
        }
    }
}
