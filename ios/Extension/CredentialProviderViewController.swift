import AuthenticationServices
import Foundation

/// SkiPass AutoFill credential provider (docs/ARCHITECTURE.md §3).
///
/// All paths are silent: a code is supplied when one is found, otherwise the request is
/// cancelled without showing anything (no UI on quota exhaustion / no match / errors).
///
/// Every entry point ends in exactly one `complete…` or `cancelRequest` call through
/// `ExtensionRequestGate`: a request superseded by a newer one never reaches the
/// context, and the work holds this controller until it finishes, so a released controller cannot
/// leave a request without an answer.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    /// nil when the mailbox store is unavailable; every request then cancels. Without a server
    /// configuration the resolver still works with the local fallback rule.
    private lazy var resolver: OneTimeCodeResolver? = LiveDependencies.makeResolver()

    private let gate = ExtensionRequestGate()

    /// Keeps the one-time-code identities current whenever the extension runs, once per process, in
    /// the background (the app also registers them on launch and after a mailbox is added or removed).
    /// Every entry point touches it; the no-UI path does not necessarily load the view. Runs through
    /// the same serialized coordinator as the syncs the resolver requests.
    private func startIdentitySync() {
        LiveDependencies.syncIdentitiesOncePerProcess()
    }

    // MARK: - No-UI path (QuickType suggestion tapped)

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        startIdentitySync()
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest else {
            LiveDependencies.recordImmediateCancel(entryPoint: "noUI", reason: "not a one-time-code request")
            cancelNow(.credentialIdentityNotFound)
            return
        }
        let service = request.credentialIdentity.serviceIdentifier.identifier
        resolveAndCompleteOneTimeCode(service: service, entryPoint: "noUI", failure: .failed)
    }

    // MARK: - Paths where the system presents the view controller

    // The extension has no UI of its own (docs/ARCHITECTURE.md §3 step 5). The three methods below run the same
    // resolver and complete immediately, or cancel with .userCanceled, adding no views.

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        startIdentitySync()
        // Lower indices are the more specific identifiers (ASCredentialProviderViewController documentation).
        resolveAndCompleteOneTimeCode(service: serviceIdentifiers.first?.identifier, entryPoint: "credentialList",
                                      failure: .userCanceled)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        startIdentitySync()
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest else {
            LiveDependencies.recordImmediateCancel(entryPoint: "interface", reason: "not a one-time-code request")
            cancelNow(.credentialIdentityNotFound)
            return
        }
        let service = request.credentialIdentity.serviceIdentifier.identifier
        resolveAndCompleteOneTimeCode(service: service, entryPoint: "interface", failure: .userCanceled)
    }

    /// iOS 18.4+ calls this instead of `prepareInterfaceToProvideCredential` for one-time-code
    /// fields in some cases, and iOS 18 requires it to avoid "AutoFill Unavailable" (seen in the feasibility probe, tools/probe/).
    /// No service identifier is available here, so the newest code email is used (docs/ARCHITECTURE.md §3 step 5).
    override func prepareInterfaceForUserChoosingTextToInsert() {
        startIdentitySync()
        guard let resolver else {
            LiveDependencies.recordImmediateCancel(entryPoint: "textToInsert", reason: "mailbox store unavailable")
            cancelNow(.userCanceled)
            return
        }
        gate.run(
            resolve: { await resolver.resolve(service: nil, entryPoint: "textToInsert") },
            complete: { resolved in
                self.extensionContext.completeRequest(
                    withTextToInsert: resolved.code,
                    completionHandler: Self.fillReporter(resolver: resolver, messageID: resolved.messageID)
                )
            },
            cancel: { self.extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled)) }
        )
    }

    // MARK: - Private

    private func cancelNow(_ code: ASExtensionError.Code) {
        gate.finishNow { extensionContext.cancelRequest(withError: ASExtensionError(code)) }
    }

    /// `entryPoint` names the system call for the diagnostics trace.
    private func resolveAndCompleteOneTimeCode(service: String?, entryPoint: String, failure: ASExtensionError.Code) {
        guard let resolver else {
            LiveDependencies.recordImmediateCancel(entryPoint: entryPoint, reason: "mailbox store unavailable")
            cancelNow(failure)
            return
        }
        gate.run(
            resolve: { await resolver.resolve(service: service, entryPoint: entryPoint) },
            complete: { resolved in
                self.extensionContext.completeOneTimeCodeRequest(
                    using: ASOneTimeCodeCredential(code: resolved.code),
                    completionHandler: Self.fillReporter(resolver: resolver, messageID: resolved.messageID)
                )
            },
            cancel: { self.extensionContext.cancelRequest(withError: ASExtensionError(failure)) }
        )
    }

    /// Completion handler that counts the fill (docs/ARCHITECTURE.md §3: fire-and-forget after completion).
    ///
    /// The system runs this handler after the request completes and passes `expired == true`
    /// when it ends that time early. The handler itself never blocks: on the
    /// first non-expired invocation it starts the fill report and returns at once.
    ///
    /// To keep the process from being suspended before the report is sent, the wait happens in a
    /// `ProcessInfo.performExpiringActivity` block instead, which runs on its own concurrent
    /// queue and holds a task assertion while it executes (Apple docs: "Performs the specified
    /// block asynchronously and notifies you if the process is about to be suspended"). That
    /// block waits at most `reportWait` (room for the fill-report retries) and stops as soon as
    /// the system reports expiry. The report result is ignored either way.
    private static func fillReporter(resolver: OneTimeCodeResolver,
                                     messageID: String) -> @Sendable (Bool) -> Void {
        let reportWait: DispatchTimeInterval = .seconds(20)
        return { expired in
            guard !expired else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await resolver.reportFill(messageID: messageID)
                done.signal()
            }
            ProcessInfo.processInfo.performExpiringActivity(withReason: "Report SkiPass fill") { activityExpired in
                // An expired call (no assertion, or suspension imminent) releases a waiting call.
                if activityExpired {
                    done.signal()
                    return
                }
                _ = done.wait(timeout: .now() + reportWait)
            }
        }
    }
}
