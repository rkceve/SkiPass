import Foundation
@preconcurrency import AppAuthCore
import SkiPassModels

/// Google / Microsoft OAuth for IMAP XOAUTH2 via AppAuth-iOS 3.0.0.
///
/// This file uses only `AppAuthCore` (token refresh + archiving), which AppAuth split out
/// "to support iOS extensions" (CHANGELOG.md L117-L118) and which AppAuth's own extension example
/// imports alone (Examples/Example-iOS_Swift-Carthage/Example_Extension/TodayViewController.swift L21).
/// Interactive sign-in lives in SkiPassAuthUI (`OAuthService+SignIn.swift`; needs the `AppAuth` UI target).
public struct OAuthService: Sendable {
    public let clients: OAuthClientConfiguration

    public init(clients: OAuthClientConfiguration = .fromInfoPlist()) {
        self.clients = clients
    }

    /// A valid access token, refreshing it first if needed, plus the (possibly updated) archived
    /// auth state, which the caller must persist (Microsoft rotates refresh tokens).
    /// Usable from the AutoFill extension: needs no UI and no client configuration.
    public func freshAccessToken(authStateData: Data) async throws -> (token: String, updatedStateData: Data) {
        let state = try Self.unarchive(authStateData)
        let queue = DispatchQueue(label: "io.github.rkceve.skipass.oauth-refresh")
        return try await withCheckedThrowingContinuation { continuation in
            // OIDAuthState.h L246-L249: calls back with a valid token, refreshing first if needed.
            state.performAction(freshTokens: { accessToken, _, error in
                guard let accessToken else {
                    continuation.resume(throwing: error ?? OAuthError.noAccessToken)
                    return
                }
                do {
                    continuation.resume(returning: (accessToken, try Self.archive(state)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }, additionalRefreshParameters: nil, dispatchQueue: queue)
        }
    }

    /// `NSKeyedArchiver` data of `OIDAuthState` (docs/ARCHITECTURE.md §5; `OIDAuthState` is NSSecureCoding,
    /// OIDAuthState.h L60). Same calls as AppAuth's SPM example (AuthManager.swift L394, L410).
    package static func archive(_ state: OIDAuthState) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
    }

    package static func unarchive(_ data: Data) throws -> OIDAuthState {
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else {
            throw OAuthError.invalidAuthState
        }
        return state
    }

    /// Address of the signed-in account, from the ID token of the latest token response.
    package static func address(of state: OIDAuthState, loginHint: String?) throws -> String {
        let claims = state.lastTokenResponse?.idToken
            .flatMap { OIDIDToken(idTokenString: $0) }?
            .claims as? [String: Any]
        return try OAuthProviderSettings.address(fromClaims: claims, loginHint: loginHint)
    }
}
