import Foundation
import SkiPassModels

public enum OAuthError: Error, Equatable, Sendable {
    /// `.imap` mailboxes have no OAuth provider.
    case unsupportedProvider(ProviderKind)
    /// Info.plist key `GoogleClientID` / `MicrosoftClientID` is missing or empty.
    case missingClientID(ProviderKind)
    /// A Google client ID not of the form `<prefix>.apps.googleusercontent.com`.
    case invalidGoogleClientID
    /// The authorization flow ended without an auth state and without an error.
    case signInFailed
    /// The token endpoint returned no access token.
    case noAccessToken
    /// Stored data is not an archived `OIDAuthState`.
    case invalidAuthState
    /// Neither the ID token nor the login hint gives the mailbox address.
    case missingAddress
    /// The Keychain has no OAuth state / password for this mailbox.
    case missingStoredSecret(mailboxID: UUID)
}

/// Client IDs read from Info.plist keys `GoogleClientID` / `MicrosoftClientID` (docs/ARCHITECTURE.md §1).
public struct OAuthClientConfiguration: Sendable, Equatable {
    public var googleClientID: String?
    public var microsoftClientID: String?

    public init(googleClientID: String?, microsoftClientID: String?) {
        self.googleClientID = googleClientID
        self.microsoftClientID = microsoftClientID
    }

    public static func fromInfoPlist(_ bundle: Bundle = .main) -> OAuthClientConfiguration {
        OAuthClientConfiguration(
            googleClientID: configuredValue(bundle.object(forInfoDictionaryKey: "GoogleClientID")),
            microsoftClientID: configuredValue(bundle.object(forInfoDictionaryKey: "MicrosoftClientID"))
        )
    }

    /// Placeholder client IDs of `ios/Config/Secrets.example.xcconfig`. A build made without the
    /// `GOOGLE_CLIENT_ID` / `MICROSOFT_CLIENT_ID` secrets carries these; sending them to the
    /// provider only produces its "invalid client / access blocked" page.
    package static let exampleClientIDs: Set<String> = [
        "000000000000-example.apps.googleusercontent.com",
        "00000000-0000-0000-0000-000000000000",
    ]

    /// A real, substituted Info.plist value: nil for a missing / non-string value, an empty string
    /// or a literal "$(NAME)" (unset xcconfig variable), and the example placeholders.
    package static func configuredValue(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !exampleClientIDs.contains(trimmed) else { return nil }
        return trimmed
    }

    /// True when sign-in with `kind` can start: its client ID is present and well-formed.
    /// Checked before any provider page is opened.
    public func isConfigured(_ kind: ProviderKind) -> Bool {
        (try? OAuthProviderSettings.settings(for: kind, clients: self)) != nil
    }
}

/// Per-provider OAuth settings.
package struct OAuthProviderSettings: Sendable, Equatable {
    package let clientID: String
    /// OpenID Connect issuer; discovery document at `<issuer>/.well-known/openid-configuration`.
    package let issuer: URL
    package let scopes: [String]
    package let redirectURL: URL
    /// Build the service configuration from the discovered endpoints only, without the issuer.
    ///
    /// Microsoft's `/common` discovery document publishes the placeholder issuer
    /// `https://login.microsoftonline.com/{tenantid}/v2.0`, while ID tokens carry the real tenant
    /// (`9188040d-6c67-4c5b-b112-36a304b66dad` for personal accounts). AppAuth rejects an ID token
    /// whose `iss` differs from `configuration.issuer` unless the issuer is nil
    /// (OIDAuthorizationService.m L596-L605).
    package let omitIssuer: Bool

    /// Fixed (docs/ARCHITECTURE.md §1), deliberately not built from the runtime bundle ID: a sideloaded build's
    /// ID carries a team suffix, and Entra only string-matches the redirect against the app
    /// registration ("AADSTS50011: The reply URL specified in the request does not match";
    /// https://learn.microsoft.com/en-us/entra/identity-platform/reply-url). Bundle-ID checks exist
    /// only inside MSAL / the broker, which AppAuth does not use. ASWebAuthenticationSession
    /// receives the callback for its `callbackURLScheme` (AppAuth 3.0.0
    /// OIDExternalUserAgentIOS.m L100-L108), so the scheme also works without a URL-type registration.
    /// Google's redirect is the reversed client ID, likewise independent of the bundle ID.
    package static let microsoftRedirect = URL(string: "msauth.io.github.rkceve.skipass://auth")!

    package static func settings(for kind: ProviderKind, clients: OAuthClientConfiguration) throws -> OAuthProviderSettings {
        switch kind {
        case .google:
            guard let clientID = clients.googleClientID else { throw OAuthError.missingClientID(.google) }
            return OAuthProviderSettings(
                clientID: clientID,
                issuer: URL(string: "https://accounts.google.com")!,
                // IMAP/XOAUTH2 scope, plus `openid email` so the ID token names the signed-in address.
                scopes: ["https://mail.google.com/", "openid", "email"],
                redirectURL: try googleRedirectURL(clientID: clientID),
                omitIssuer: false
            )
        case .microsoft:
            guard let clientID = clients.microsoftClientID else { throw OAuthError.missingClientID(.microsoft) }
            return OAuthProviderSettings(
                clientID: clientID,
                issuer: URL(string: "https://login.microsoftonline.com/common/v2.0")!,
                // IMAP scope + refresh token, plus `openid email` so the ID token names the address.
                scopes: ["https://outlook.office.com/IMAP.AccessAsUser.All", "offline_access", "openid", "email"],
                redirectURL: microsoftRedirect,
                omitIssuer: true
            )
        case .imap:
            throw OAuthError.unsupportedProvider(.imap)
        }
    }

    /// `com.googleusercontent.apps.<GOOGLE_CLIENT_ID_PREFIX>:/oauth2redirect` (docs/ARCHITECTURE.md §1): the
    /// client ID with its dot-separated fields reversed, used as a custom scheme.
    package static func googleRedirectURL(clientID: String) throws -> URL {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix), clientID.count > suffix.count else {
            throw OAuthError.invalidGoogleClientID
        }
        let prefix = clientID.dropLast(suffix.count)
        guard let url = URL(string: "com.googleusercontent.apps.\(prefix):/oauth2redirect") else {
            throw OAuthError.invalidGoogleClientID
        }
        return url
    }

    /// The signed-in mailbox address from ID token claims: `email`, then Microsoft's
    /// `preferred_username` if it looks like an address, then the address the user typed.
    package static func address(fromClaims claims: [String: Any]?, loginHint: String?) throws -> String {
        if let email = claims?["email"] as? String, email.contains("@") { return email }
        if let preferred = claims?["preferred_username"] as? String, preferred.contains("@") { return preferred }
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), hint.contains("@") { return hint }
        throw OAuthError.missingAddress
    }
}
