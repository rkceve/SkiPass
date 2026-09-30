import Foundation
import os
import SkiPassAuth
import SkiPassExtraction
import SkiPassMail
import SkiPassModels
import SkiPassServerClient
import SkiPassStorage

/// Wiring of the concrete SkiPassCore implementations into `OneTimeCodeResolver`.
///
/// This is the only file that names concrete types from SkiPassStorage, SkiPassMail, SkiPassAuth,
/// SkiPassExtraction and SkiPassServerClient. Symbols used (same as ios/App/LiveServices.swift):
///   - SkiPassStorage: `MailboxStore() throws`, `.list()`; `AppGroupState() throws`, `.revenueCatAppUserID`;
///                     `SharedStorageEnvironment.current.defaults` / `.appGroupID`
///   - SkiPassAuth:    `OAuthCredentialProvider()`: `CredentialProviding`
///   - SkiPassMail:    `IMAPMailFetcher(credentials:timeout:)`: `MailFetching`
///   - SkiPassExtraction: `OTPCodeExtractor()`: `CodeExtracting`
///   - SkiPassServerClient: `ServerClient(configuration: ServerClientConfiguration(baseURL:appToken:appUserID:timeout:anonymousJudgeUserID:))`,
///     conforming to `CandidateJudging` and `UsageReporting`; `ServerBuildConfiguration(bundle:)` (Info.plist values)
enum LiveDependencies {

    /// `X-SkiPass-User` for judging when the App Group holds no app user ID.
    static let anonymousJudgeUserID = "anonymous"

    /// Total time for one server request. Above the server's worst case (3 s upstream timeout plus a
    /// cold start), so the server's own answer (e.g. 402) normally arrives before the local fallback
    /// takes over; the mailbox budget (8 s) is separate.
    static let serverTimeout: TimeInterval = 7

    private static let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "Extension")

    /// One line per AutoFill stage (subsystem = this bundle's id, category "autofill"). Lines are built
    /// only from non-secret values (masked addresses, counts, folder names, error summaries), so they
    /// are public: `log stream --predicate 'category == "autofill"'` or Console.app shows them.
    private static let autofillLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.rkceve.skipass",
                                               category: "autofill")

    /// Returns nil only when the mailbox store is unavailable (the extension then cancels silently).
    ///
    /// The server judges when it is configured and reachable; otherwise (no URL / token in this build,
    /// or any request error, including 429) the on-device copy of the server's fallback rule picks the
    /// code, so filling keeps working with the server down. Without an app user ID the server still
    /// judges (anonymously) but nothing is counted. Fill reports are retried up to 3 times;
    /// their final error is ignored.
    static func makeResolver(bundle: Bundle = .main) -> OneTimeCodeResolver? {
        guard let mailboxStore = try? MailboxStore() else { return nil }
        let server = makeServerClient(bundle: bundle)
        let seen = seenDomains()
        let budget = OneTimeCodeResolver.defaultPerMailboxBudget
        return OneTimeCodeResolver(
            mailboxes: { try mailboxStore.list() },
            fetcher: IMAPMailFetcher(credentials: OAuthCredentialProvider(),
                                     timeout: max(0.5, seconds(budget - OneTimeCodeResolver.fetchMargin))),
            extractor: OTPCodeExtractor(),
            judge: FallbackJudge(primary: server),
            usage: server.map { $0 as any UsageReporting } ?? NoServerUsage(),
            perMailboxBudget: budget,
            fillReportRetry: FillReportRetry(shouldRetry: isWorthRetrying),
            chosenObserver: { message in
                // Domains of the email that was used become identities for the next visit.
                if seen.record(EmailDomains.domains(in: message)) { requestIdentitySync() }
            },
            diagnostics: resolverDiagnostics
        )
    }

    // MARK: - Diagnostics

    /// The diagnostics records in this process's shared defaults (the app reads the same ones when
    /// both processes resolved the same App Group).
    static func diagnosticsStore() -> DiagnosticsStore {
        DiagnosticsStore(defaults: SharedStorageEnvironment.current.defaults)
    }

    /// Logs every stage, adds this process's groups (and whether they equal the app's) at the start,
    /// and keeps the finished trace in the shared defaults.
    static let resolverDiagnostics = ResolverDiagnostics(
        log: { line in autofillLogger.notice("\(line, privacy: .public)") },
        prepare: { trace in
            let (storage, match) = storageComparison()
            trace.storage = storage
            trace.groupsMatchApp = match
        },
        finish: { trace in diagnosticsStore().append(trace) }
    )

    /// This process's groups and whether the app recorded the same ones (nil: no app record visible,
    /// e.g. because this process has no App Group and reads its private defaults).
    static func storageComparison() -> (StorageSnapshot, Bool?) {
        let environment = SharedStorageEnvironment.current
        let storage = StorageSnapshot(bundleID: Bundle.main.bundleIdentifier, appGroup: environment.appGroupID,
                                      keychainGroup: environment.keychainAccessGroup, recordedAt: Date())
        let match = diagnosticsStore().appStorage().map { $0.sharesGroups(with: storage) }
        return (storage, match)
    }

    /// Records a request that ends before the resolver runs (not a one-time-code request).
    static func recordImmediateCancel(entryPoint: String, reason: String) {
        var trace = AutoFillTrace(startedAt: Date(), entryPoint: entryPoint, service: nil)
        resolverDiagnostics.prepare(&trace)
        trace.outcome = "cancelled"
        trace.reason = reason
        trace.totalMs = 0
        resolverDiagnostics.log("[\(trace.id.uuidString.prefix(8))] request \(entryPoint) cancelled at once: \(reason)")
        resolverDiagnostics.finish(trace)
    }

    /// Server client, or nil when this build lacks the server configuration. A missing app user ID
    /// does not disable the server: it is logged, judging uses `anonymousJudgeUserID`,
    /// and fills are not reported until the app has written the ID.
    static func makeServerClient(bundle: Bundle) -> ServerClient? {
        // Unset values and the Secrets.example placeholders mean "no server" (same rule as the app).
        guard let config = ServerBuildConfiguration(bundle: bundle) else {
            logger.notice("No server configuration in this build; using the local fallback rule only")
            return nil
        }
        let sharedState = try? AppGroupState()
        if (sharedState?.revenueCatAppUserID ?? "").isEmpty {
            logger.error("No app user ID (rc.appUserID) in the App Group defaults: judging via the server without a user, fills are not counted")
        }
        return ServerClient(configuration: ServerClientConfiguration(
            baseURL: config.baseURL,
            appToken: config.appToken,
            // Read on every request, so an ID the app writes later is used at once.
            appUserID: { sharedState?.revenueCatAppUserID },
            timeout: serverTimeout,
            anonymousJudgeUserID: anonymousJudgeUserID
        ))
    }

    /// Fill reports are retried only for errors a later attempt can fix.
    @Sendable static func isWorthRetrying(_ error: any Error) -> Bool {
        if let error = error as? ServerClientError {
            if error == .missingAppUserID {
                logger.error("Fill not reported: no app user ID")
            }
            return error.isTransient
        }
        return error is URLError
    }

    static func seenDomains() -> SeenDomainStore {
        SeenDomainStore(defaults: SharedStorageEnvironment.current.defaults)
    }

    // MARK: - Identity registration

    /// One registration at a time; overlapping requests share one follow-up run.
    private static let identitySync = IdentitySyncCoordinator { _ = await syncIdentities() }

    private static let identitySyncAtLaunch: Void = requestIdentitySync()

    /// Starts one registration per extension process (the app also registers on launch and after a
    /// mailbox is added or removed).
    static func syncIdentitiesOncePerProcess() {
        _ = identitySyncAtLaunch
    }

    /// Asks for a registration in the background; returns at once.
    static func requestIdentitySync() {
        Task.detached(priority: .utility) { await identitySync.sync() }
    }

    /// Re-registers the one-time-code identities (bundled + demo + seen domains) for the stored
    /// mailboxes. Runs in the background; the result is only logged. When the mailbox list cannot be
    /// read (or this process has no App Group), the store is left as it is instead of being emptied.
    @discardableResult
    static func syncIdentities(bundle: Bundle = .main) async -> IdentityRegistrar.Result? {
        let input = IdentitySyncInput.decide(appGroupResolved: SharedStorageEnvironment.current.appGroupID != nil,
                                             list: { try MailboxStore().list() })
        switch input {
        case .keepExisting(let reason):
            logger.error("Identity sync skipped: \(reason, privacy: .public)")
            autofillLogger.notice("identity registration (extension) skipped: \(reason, privacy: .public)")
            diagnosticsStore().setRegistration(RegistrationRecord(process: "extension", at: Date(), outcome: "skipped",
                                                                  detail: reason))
            return nil
        case .register(let addresses):
            let registrar = IdentityRegistrar(domainSource: CompositeDomainSource.standard(bundle: bundle, seen: seenDomains()))
            let result = await registrar.register(mailboxAddresses: addresses)
            let record = result.record(process: "extension", at: Date())
            logger.notice("Identity sync: \(String(describing: result), privacy: .public)")
            autofillLogger.notice("identity registration (extension): \(record.summary, privacy: .public)")
            diagnosticsStore().setRegistration(record)
            return result
        }
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
