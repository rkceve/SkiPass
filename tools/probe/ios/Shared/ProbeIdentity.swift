// CI probe (not shipped): shared between SkiPassProbe and SkiPassProbeAutoFill.
import AuthenticationServices

enum ProbeIdentity {
    /// Host of the probe page deployed from tools/probe/site/ by .github/workflows/pages.yml.
    static let domain = "rkceve.github.io"
    static let label = "From probe@example.com"
    static let recordIdentifier = "probe-otp-1"
    static let code = "123456"

    static func makeIdentity() -> ASOneTimeCodeCredentialIdentity {
        ASOneTimeCodeCredentialIdentity(
            serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
            label: label,
            recordIdentifier: recordIdentifier
        )
    }

    /// Replaces the store contents with the single probe identity.
    /// Completion receives a human-readable status line.
    static func register(completion: @escaping @Sendable (String) -> Void) {
        ASCredentialIdentityStore.shared.getState { state in
            guard state.isEnabled else {
                completion("store disabled")
                return
            }
            ASCredentialIdentityStore.shared.replaceCredentialIdentities([makeIdentity()]) { ok, error in
                if ok {
                    completion("registered")
                } else {
                    completion("register failed: \(error.map { String(describing: $0) } ?? "unknown")")
                }
            }
        }
    }
}
