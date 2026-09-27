import Foundation
import SkiPassModels
import os

/// Configuration for `ServerClient` (values come from Info.plist keys `SkiPassServerURL` /
/// `SkiPassAppToken` and the App Group key `rc.appUserID`, CONTRACTS §2 and §4).
public struct ServerClientConfiguration: Sendable {
    /// Worker base URL, e.g. `https://skipass-server.example.workers.dev`.
    public var baseURL: URL
    /// Sent as `X-SkiPass-App-Token`.
    public var appToken: String
    /// Returns the RevenueCat app user ID, sent as `X-SkiPass-User`; nil or empty = not available yet.
    public var appUserID: @Sendable () -> String?
    /// Total time allowed for one request, in seconds (connection, server work and body).
    public var timeout: TimeInterval
    /// Sent as `X-SkiPass-User` on `POST /v1/judge` only, when `appUserID` has no value (TRIAGE D10:
    /// the extension still asks the server to judge without an app user ID, and counts nothing). Nil =
    /// no request is made without an app user ID. Fills and usage always need the real ID.
    public var anonymousJudgeUserID: String?

    public init(baseURL: URL, appToken: String,
                appUserID: @escaping @Sendable () -> String?,
                timeout: TimeInterval = 10,
                anonymousJudgeUserID: String? = nil) {
        self.baseURL = baseURL
        self.appToken = appToken
        self.appUserID = appUserID
        self.timeout = timeout
        self.anonymousJudgeUserID = anonymousJudgeUserID
    }
}

public enum ServerClientError: Error, Equatable, Sendable {
    /// 402 `{"error":"quota_exhausted","remaining":0}` from `POST /v1/fills`.
    case quotaExhausted
    /// 401 `{"error":"unauthorized"}`.
    case unauthorized
    /// 401 `{"error":"unknown_user"}`: RevenueCat does not know `X-SkiPass-User` (TRIAGE D1; e.g. a
    /// `local:<uuid>` ID from a build without RevenueCat, D10). Treated like an unavailable server.
    case unknownUser
    /// 429 `{"error":"rate_limited"}` (TRIAGE D1).
    case rateLimited
    /// No RevenueCat app user ID available to send.
    case missingAppUserID
    /// The request did not finish within `ServerClientConfiguration.timeout`.
    case timedOut
    /// Any other non-success status.
    case httpStatus(Int)
    /// The response was not HTTP or its body did not match CONTRACTS §5.
    case invalidResponse

    /// Worth retrying later (network trouble, timeouts, rate limiting, server errors). Answers that
    /// will not change on a retry (quota, auth, bad request, missing ID) are not.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .timedOut: return true
        case .httpStatus(let status): return status >= 500 || status == 408
        case .quotaExhausted, .unauthorized, .unknownUser, .missingAppUserID, .invalidResponse: return false
        }
    }
}

/// Client for the SkiPass server HTTP API (CONTRACTS §5).
public struct ServerClient: CandidateJudging, UsageReporting {
    public let configuration: ServerClientConfiguration
    private let session: URLSession

    /// `source` values the server may report (CONTRACTS §5; `mock` added by TRIAGE D3).
    static let knownSources: Set<String> = ["jev", "fallback", "mock"]

    private static let logger = Logger(subsystem: "io.github.rkceve.skipass", category: "ServerClient")

    public init(configuration: ServerClientConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: CandidateJudging

    /// `POST /v1/judge`. Does not count usage. 402 maps to `.quotaExhausted`.
    ///
    /// A 200 reply is accepted only when it names one of the messages sent (or none), reports a known
    /// `source`, and a non-negative `remaining`; anything else throws `.invalidResponse`, so the caller's
    /// local fallback runs (A2-06, SYSTEM §3.4 "bad reply").
    public func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome {
        // The server rejects an empty list; with nothing to judge there is no match.
        guard !messages.isEmpty else { return .noMatch(scores: [:]) }
        let body = JudgeRequest(service: service,
                                messages: messages.map { .init(id: $0.id, text: $0.judgeText) })
        let (data, status) = try await send(path: "v1/judge", method: "POST", body: body,
                                            anonymousUser: configuration.anonymousJudgeUserID)
        switch status {
        case 200:
            let decoded = try decode(JudgeResponse.self, from: data)
            let sent = Set(messages.map(\.id))
            let chosenWasSent = decoded.chosenId.map { sent.contains($0) } ?? true
            let source = decoded.source
            guard Self.knownSources.contains(source), decoded.remaining >= 0,
                  decoded.scores.values.allSatisfy({ $0.isFinite }), chosenWasSent
            else {
                Self.logger.error("v1/judge: reply rejected (source \(source, privacy: .public), chosen id was sent: \(chosenWasSent, privacy: .public))")
                throw ServerClientError.invalidResponse
            }
            if let chosen = decoded.chosenId {
                return .chosen(messageID: chosen, scores: decoded.scores)
            }
            return .noMatch(scores: decoded.scores)
        case 402:
            try requireQuotaBody(data, path: "v1/judge")
            return .quotaExhausted
        default:
            throw failure(status: status, body: data, path: "v1/judge")
        }
    }

    // MARK: UsageReporting

    /// `POST /v1/fills`. Counts one fill and returns the remaining fills.
    @discardableResult
    public func reportFill(messageID: String) async throws -> Int {
        let (data, status) = try await send(path: "v1/fills", method: "POST",
                                            body: FillRequest(messageId: messageID), anonymousUser: nil)
        switch status {
        case 200: return try decode(FillResponse.self, from: data).remaining
        case 402:
            try requireQuotaBody(data, path: "v1/fills")
            throw ServerClientError.quotaExhausted
        default: throw failure(status: status, body: data, path: "v1/fills")
        }
    }

    /// `GET /v1/usage`.
    public func currentUsage() async throws -> UsageSnapshot {
        let (data, status) = try await send(path: "v1/usage", method: "GET", body: Optional<FillRequest>.none,
                                            anonymousUser: nil)
        guard status == 200 else { throw failure(status: status, body: data, path: "v1/usage") }
        let u = try decode(UsageResponse.self, from: data)
        return UsageSnapshot(plan: u.plan, used: u.used, limit: u.limit, resetsAt: u.resetsAt)
    }

    // MARK: Transport

    private func send<Body: Encodable & Sendable>(path: String, method: String, body: Body?,
                                                  anonymousUser: String?) async throws -> (Data, Int) {
        let user: String
        if let id = configuration.appUserID(), !id.isEmpty {
            user = id
        } else if let anonymousUser, !anonymousUser.isEmpty {
            user = anonymousUser
        } else {
            throw ServerClientError.missingAppUserID
        }
        var request = URLRequest(url: configuration.baseURL.appending(path: path),
                                 timeoutInterval: configuration.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.appToken, forHTTPHeaderField: "X-SkiPass-App-Token")
        request.setValue(user, forHTTPHeaderField: "X-SkiPass-User")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        // `timeoutInterval` only limits idle time between packets; the race below bounds the whole
        // request, so a slow server hands over to the local fallback on time (A2-08).
        let (data, status) = try await Self.withTotalTimeout(configuration.timeout) { [session, request] () async throws -> (Data, Int?) in
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode)
        }
        guard let status else { throw ServerClientError.invalidResponse }
        return (data, status)
    }

    /// Runs `operation`, throwing `ServerClientError.timedOut` after `seconds` (the operation is cancelled).
    static func withTotalTimeout<T: Sendable>(_ seconds: TimeInterval,
                                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw ServerClientError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ServerClientError.timedOut }
            return first
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ServerClientError.invalidResponse
        }
    }

    /// A 402 counts as quota exhaustion only with the contract body; anything else (a proxy page,
    /// another service) is a bad reply.
    private func requireQuotaBody(_ data: Data, path: String) throws {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data), body.error == "quota_exhausted" else {
            Self.logger.error("\(path, privacy: .public): 402 without a quota_exhausted body")
            throw ServerClientError.invalidResponse
        }
    }

    /// Maps a non-success status and logs it (A2-07: a wrong server URL or rejected header is otherwise
    /// invisible, because the extension silently falls back to the local rule).
    private func failure(status: Int, body: Data, path: String) -> ServerClientError {
        let errorCode = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error ?? "-"
        switch status {
        case 400, 404, 405, 413:
            Self.logger.error("\(path, privacy: .public): HTTP \(status, privacy: .public) \(errorCode, privacy: .public) (configuration error? check SkiPassServerURL and the request headers)")
        default:
            Self.logger.error("\(path, privacy: .public): HTTP \(status, privacy: .public) \(errorCode, privacy: .public)")
        }
        switch status {
        case 401: return errorCode == "unknown_user" ? .unknownUser : .unauthorized
        case 429: return .rateLimited
        default: return .httpStatus(status)
        }
    }
}

// MARK: Wire types (CONTRACTS §5)

struct JudgeRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let id: String
        let text: String
    }

    let service: String?
    let messages: [Message]

    private enum CodingKeys: String, CodingKey { case service, messages }

    // `service` is always present, as a string or JSON null.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let service {
            try c.encode(service, forKey: .service)
        } else {
            try c.encodeNil(forKey: .service)
        }
        try c.encode(messages, forKey: .messages)
    }
}

struct JudgeResponse: Decodable {
    let chosenId: String?
    let scores: [String: Double]
    let remaining: Int
    let source: String
}

struct FillRequest: Encodable, Sendable {
    let messageId: String
}

struct FillResponse: Decodable {
    let remaining: Int
}

struct UsageResponse: Decodable {
    let plan: String
    let used: Int
    let limit: Int
    let resetsAt: Date
}

struct ErrorBody: Decodable {
    let error: String
}
