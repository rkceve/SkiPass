import Foundation

/// Server settings baked into a build's Info.plist (CONTRACTS §2: `SkiPassServerURL`,
/// `SkiPassAppToken`), with unset values and the placeholders of `ios/Config/Secrets.example.xcconfig`
/// meaning "not configured" (same rule as the app's `AppConfiguration`).
public struct ServerBuildConfiguration: Sendable, Equatable {
    public static let serverURLKey = "SkiPassServerURL"
    public static let appTokenKey = "SkiPassAppToken"

    /// Placeholders of `ios/Config/Secrets.example.xcconfig`, kept by builds made without the
    /// corresponding secret.
    public static let exampleValues: Set<String> = [
        "https://skipass.example.invalid",
        "example-app-token",
        "appl_example",
    ]

    public var baseURL: URL
    public var appToken: String

    /// Nil unless both values are real: a non-empty, substituted string that is not a placeholder,
    /// and an absolute URL with a scheme and host.
    public init?(info: [String: Any]) {
        guard let urlString = Self.value(Self.serverURLKey, in: info),
              let url = URL(string: urlString), url.scheme != nil, url.host() != nil,
              let token = Self.value(Self.appTokenKey, in: info)
        else { return nil }
        baseURL = url
        appToken = token
    }

    public init?(bundle: Bundle) {
        self.init(info: bundle.infoDictionary ?? [:])
    }

    /// Trimmed Info.plist string, or nil when missing, empty, unsubstituted (`$(NAME)`) or a placeholder.
    public static func value(_ key: String, in info: [String: Any]) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$("), !exampleValues.contains(value) else { return nil }
        return value
    }
}
