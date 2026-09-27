import Foundation
import SkiPassAuth
import SkiPassExtraction
import SkiPassMail
import SkiPassModels
import SkiPassServerClient
import SkiPassStorage

/// Wiring of the concrete SkiPassCore implementations into `OneTimeCodeResolver`.
///
/// This is the only file that names concrete types from I2 (Storage/Mail/Auth),
/// I3 (Extraction) and I5 (ServerClient). Symbols used (same as ios/App/LiveServices.swift):
///   - SkiPassStorage: `MailboxStore() throws`, `.list()`; `AppGroupState() throws`, `.revenueCatAppUserID`;
///                     `SharedStorageEnvironment.current.defaults`
///   - SkiPassAuth:    `OAuthCredentialProvider()`: `CredentialProviding`
///   - SkiPassMail:    `IMAPMailFetcher(credentials:timeout:)`: `MailFetching`
///   - SkiPassExtraction: `OTPCodeExtractor()`: `CodeExtracting`
///   - SkiPassServerClient: `ServerClient(configuration: ServerClientConfiguration(baseURL:appToken:appUserID:))`,
///     conforming to `CandidateJudging` and `UsageReporting`
enum LiveDependencies {

    /// Info.plist keys (CONTRACTS §2).
    static let serverURLKey = "SkiPassServerURL"
    static let appTokenKey = "SkiPassAppToken"

    /// Returns nil only when the mailbox store is unavailable (the extension then cancels silently).
    ///
    /// The server judges when it is configured and reachable; otherwise (no URL / token / RevenueCat
    /// app user ID in this build, or any request error) the on-device copy of the server's fallback
    /// rule picks the code, so filling keeps working with the server down. Fills are reported to
    /// the server when there is one; the report's errors are ignored.
    static func makeResolver(bundle: Bundle = .main) -> OneTimeCodeResolver? {
        guard let mailboxStore = try? MailboxStore() else { return nil }
        let server = makeServerClient(bundle: bundle)
        let seen = seenDomains()
        return OneTimeCodeResolver(
            mailboxes: { try mailboxStore.list() },
            // The fetcher's own wall-clock limit matches the resolver's per-mailbox budget
            // (CONTRACTS §6: 4 s), so a timed-out fetch also drops its IMAP connection.
            fetcher: IMAPMailFetcher(credentials: OAuthCredentialProvider(),
                                     timeout: seconds(OneTimeCodeResolver.defaultPerMailboxBudget)),
            extractor: OTPCodeExtractor(),
            judge: FallbackJudge(primary: server),
            usage: server.map { $0 as any UsageReporting } ?? NoServerUsage(),
            candidateObserver: { messages in
                // Domains of verification emails become identities for the next visit.
                let changed = seen.record(messages.flatMap(EmailDomains.domains(in:)))
                if changed { Task.detached { _ = await syncIdentities() } }
            }
        )
    }

    /// Server client, or nil when this build or this install lacks its configuration.
    static func makeServerClient(bundle: Bundle) -> ServerClient? {
        guard let urlString = value(serverURLKey, in: bundle),
              let baseURL = URL(string: urlString), baseURL.scheme != nil,
              let appToken = value(appTokenKey, in: bundle),
              let sharedState = try? AppGroupState(),
              let appUserID = sharedState.revenueCatAppUserID, !appUserID.isEmpty
        else { return nil }
        return ServerClient(configuration: ServerClientConfiguration(
            baseURL: baseURL,
            appToken: appToken,
            appUserID: { appUserID },
            // Shorter than the 10 s default so an unreachable server falls back to the local
            // rule quickly enough for AutoFill.
            timeout: 4
        ))
    }

    static func seenDomains() -> SeenDomainStore {
        SeenDomainStore(defaults: SharedStorageEnvironment.current.defaults)
    }

    /// Re-registers the one-time-code identities (bundled + demo + seen domains) for the stored
    /// mailboxes. Runs in the background; the result is not shown anywhere.
    @discardableResult
    static func syncIdentities(bundle: Bundle = .main) async -> IdentityRegistrar.Result {
        let addresses = ((try? MailboxStore().list()) ?? []).map(\.address)
        let registrar = IdentityRegistrar(domainSource: CompositeDomainSource.standard(bundle: bundle, seen: seenDomains()))
        return await registrar.register(mailboxAddresses: addresses)
    }

    /// Non-empty, substituted Info.plist string (an unset xcconfig variable leaves "" or "$(NAME)").
    private static func value(_ key: String, in bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Usage reporting when there is no server in this build: nothing is counted.
struct NoServerUsage: UsageReporting {
    struct Unavailable: Error {}

    func reportFill(messageID: String) async throws -> Int { throw Unavailable() }
    func currentUsage() async throws -> UsageSnapshot { throw Unavailable() }
}
