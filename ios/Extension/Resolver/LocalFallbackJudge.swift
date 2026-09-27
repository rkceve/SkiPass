import Foundation
import SkiPassModels

/// On-device copy of the server's fallback rule (CONTRACTS §5; server/src/jev.ts `fallbackSelect`):
/// the newest message whose text contains the service's registrable domain, else the newest message.
/// Used when the server cannot be reached, so a code is still filled (e.g. the demo with the server down).
struct LocalFallbackJudge: CandidateJudging {
    func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome {
        guard let chosen = Self.select(service: service, messages: messages) else {
            return .noMatch(scores: [:])
        }
        return .chosen(messageID: chosen, scores: [:])
    }

    /// Mirrors `fallbackSelect`: text = `judgeText` (headers + body, what the server receives),
    /// compared lowercased; newest by `date`, the earlier message winning on equal dates.
    static func select(service: String?, messages: [FetchedMessage]) -> String? {
        if let service, let domain = EmailDomains.registrableDomain(service) {
            let matching = messages.filter { $0.judgeText.lowercased().contains(domain) }
            if let newest = newest(matching) { return newest.id }
        }
        return newest(messages)?.id
    }

    private static func newest(_ messages: [FetchedMessage]) -> FetchedMessage? {
        var best: FetchedMessage?
        for message in messages where best.map({ message.date > $0.date }) ?? true {
            best = message
        }
        return best
    }
}

/// Asks `primary` (the server) and falls back to `LocalFallbackJudge` when it throws
/// (unreachable, timeout, 5xx, 401, malformed reply) or when there is no server in this build.
/// A server answer — including `.noMatch` and `.quotaExhausted` — is final.
struct FallbackJudge: CandidateJudging {
    let primary: (any CandidateJudging)?
    var fallback: any CandidateJudging = LocalFallbackJudge()

    func judge(service: String?, messages: [FetchedMessage]) async throws -> JudgeOutcome {
        guard let primary else {
            return try await fallback.judge(service: service, messages: messages)
        }
        do {
            return try await primary.judge(service: service, messages: messages)
        } catch {
            return try await fallback.judge(service: service, messages: messages)
        }
    }
}
