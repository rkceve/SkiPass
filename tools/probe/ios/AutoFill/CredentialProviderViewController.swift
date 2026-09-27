// CI probe credential provider (not shipped). Always supplies ProbeIdentity.code.
import AuthenticationServices
import UIKit

final class CredentialProviderViewController: ASCredentialProviderViewController {
    // Non-UI path: the user tapped the QuickType suggestion for a registered identity.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        guard credentialRequest.type == .oneTimeCode else {
            extensionContext.cancelRequest(withError: ASExtensionError(.credentialIdentityNotFound))
            return
        }
        // Re-register so the identity survives store resets while the extension is enabled.
        ProbeIdentity.register { _ in }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: ProbeIdentity.code))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        showChoice(title: "Probe code") { [weak self] in
            self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: ProbeIdentity.code))
        }
    }

    // Key icon in the QuickType bar -> list of OTPs.
    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        showChoice(title: "Probe OTP list") { [weak self] in
            self?.extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: ProbeIdentity.code))
        }
    }

    // Called instead of the OTP path on iOS 18.4+ in some cases (docs/facts/F1 §2).
    override func prepareInterfaceForUserChoosingTextToInsert() {
        showChoice(title: "Probe text") { [weak self] in
            self?.extensionContext.completeRequest(withTextToInsert: ProbeIdentity.code)
        }
    }

    private func showChoice(title: String, onChoose: @escaping () -> Void) {
        view.subviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)

        let choose = UIButton(type: .system, primaryAction: UIAction(title: ProbeIdentity.code) { _ in onChoose() })
        choose.accessibilityIdentifier = "probe.ext.choose"

        let cancel = UIButton(type: .system, primaryAction: UIAction(title: "Cancel") { [weak self] _ in
            self?.extensionContext.cancelRequest(withError: ASExtensionError(.userCanceled))
        })
        cancel.accessibilityIdentifier = "probe.ext.cancel"

        let stack = UIStackView(arrangedSubviews: [label, choose, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
