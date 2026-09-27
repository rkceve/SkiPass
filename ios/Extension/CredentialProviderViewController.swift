import AuthenticationServices
import Foundation

/// SkiPass AutoFill credential provider (CONTRACTS §6).
///
/// All paths are silent: a code is supplied when one is found, otherwise the request is
/// cancelled without showing anything (decided: no UI on quota exhaustion / no match / errors).
final class CredentialProviderViewController: ASCredentialProviderViewController {

    /// nil when the mailbox store is unavailable; every request then cancels. Without a server
    /// configuration the resolver still works with the local fallback rule.
    private lazy var resolver: OneTimeCodeResolver? = LiveDependencies.makeResolver()

    /// Keeps the one-time-code identities current whenever the extension runs, once per process, in
    /// the background (the app also registers them on launch and after a mailbox is added or removed).
    /// Every entry point below touches it; the no-UI path does not necessarily load the view.
    private static let identitySync: Task<Void, Never> = Task.detached {
        _ = await LiveDependencies.syncIdentities()
    }

    private func startIdentitySync() {
        _ = Self.identitySync
    }

    // MARK: - No-UI path (QuickType suggestion tapped)

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        startIdentitySync()
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest else {
            extensionContext.cancelRequest(withError: ASExtensionError(.credentialIdentityNotFound))
            return
        }
        let service = request.credentialIdentity.serviceIdentifier.identifier
        resolveAndCompleteOneTimeCode(service: service, failure: .failed)
    }

    // MARK: - Paths where the system presents the view controller

    // OPEN(extension-ui): spec defines no extension UI. The three methods below run the same
    // resolver and complete immediately, or cancel with .userCanceled, adding no views of their own.

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        startIdentitySync()
        // Lower indices are the more specific identifiers (docs/facts/F1 §1).
        resolveAndCompleteOneTimeCode(service: serviceIdentifiers.first?.identifier, failure: .userCanceled)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        startIdentitySync()
        guard let request = credentialRequest as? ASOneTimeCodeCredentialRequest else {
            extensionContext.cancelRequest(withError: ASExtensionError(.credentialIdentityNotFound))
            return
        }
        let service = request.credentialIdentity.serviceIdentifier.identifier
        resolveAndCompleteOneTimeCode(service: service, failure: .userCanceled)
    }

    /// iOS 18.4+ calls this instead of `prepareInterfaceToProvideCredential` for one-time-code
    /// fields in some cases, and iOS 18 requires it to avoid "AutoFill Unavailable" (docs/facts/F1 §2).
    /// No service identifier is available here, so the newest code email is used (spec §5.6).
    override func prepareInterfaceForUserChoosingTextToInsert() {
        startIdentitySync()
        guard let resolver else {
            extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
            return
        }
        Task { @MainActor [weak self] in
            let resolved = await resolver.resolve(service: nil)
            guard let self else { return }
            guard let resolved else {
                self.extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
                return
            }
            self.extensionContext.completeRequest(
                withTextToInsert: resolved.code,
                completionHandler: Self.fillReporter(resolver: resolver, messageID: resolved.messageID)
            )
        }
    }

    // MARK: - Private

    private func resolveAndCompleteOneTimeCode(service: String?, failure: ASExtensionError.Code) {
        guard let resolver else {
            extensionContext.cancelRequest(withError: ASExtensionError(failure))
            return
        }
        Task { @MainActor [weak self] in
            let resolved = await resolver.resolve(service: service)
            guard let self else { return }
            guard let resolved else {
                self.extensionContext.cancelRequest(withError: ASExtensionError(failure))
                return
            }
            self.extensionContext.completeOneTimeCodeRequest(
                using: ASOneTimeCodeCredential(code: resolved.code),
                completionHandler: Self.fillReporter(resolver: resolver, messageID: resolved.messageID)
            )
        }
    }

    /// Completion handler that counts the fill (CONTRACTS §6: fire-and-forget after completion).
    ///
    /// The system runs this handler after the request completes and passes `expired == true`
    /// when it ends that time early (docs/facts/F1 §1). The handler itself never blocks: on the
    /// first non-expired invocation it starts the fill report and returns at once.
    ///
    /// To keep the process from being suspended before the report is sent, the wait happens in a
    /// `ProcessInfo.performExpiringActivity` block instead, which runs on its own concurrent
    /// queue and holds a task assertion while it executes (Apple docs: "Performs the specified
    /// block asynchronously and notifies you if the process is about to be suspended"). That
    /// block waits at most `reportWait` and stops as soon as the system reports expiry.
    /// The report result is ignored either way.
    private static func fillReporter(resolver: OneTimeCodeResolver,
                                     messageID: String) -> @Sendable (Bool) -> Void {
        let reportWait: DispatchTimeInterval = .seconds(5)
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
