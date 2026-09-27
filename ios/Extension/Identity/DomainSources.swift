import Foundation

// Concrete `IdentityDomainSource`s (user decision 2026-09-27: suggestions must appear on the first
// visit to a site, so identities are registered up front, in the background):
//   1. a bundled list of popular sign-in domains (`sign-in-domains.json`, in the app and the extension),
//   2. the demo site,
//   3. registrable domains seen in verification emails (sender + links), recorded by the extension.

/// The demo site (demo-site/, deployed on Vercel).
enum DemoSite {
    static let domain = "skipass-demo.vercel.app"
}

/// Fixed domains (the demo site).
struct FixedDomainSource: IdentityDomainSource {
    var fixed: [String] = [DemoSite.domain]

    func domains() async -> [String] { fixed }
}

/// Popular sign-in domains from the bundled `sign-in-domains.json` (`{"domains": [...]}`).
struct BundledDomainSource: IdentityDomainSource {
    static let resourceName = "sign-in-domains"

    /// Read once when the source is made (the file is small: ~100 domains).
    let bundled: [String]

    init(bundle: Bundle = .main) {
        bundled = Self.load(from: bundle)
    }

    func domains() async -> [String] {
        bundled
    }

    static func load(from bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.domains
    }

    private struct File: Decodable {
        var domains: [String]
    }
}

/// Registrable domains seen in verification emails, kept in the App Group defaults so that both
/// the extension (which reads mail) and the app (which registers on launch) use them.
/// Newest first, at most `limit` entries.
final class SeenDomainStore: IdentityDomainSource, @unchecked Sendable {
    /// App Group defaults key (JSON `[String]`).
    static let defaultsKey = "identity.seenDomains.v1"
    static let limit = 100

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func domains() async -> [String] {
        stored()
    }

    func stored() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// Adds domains (moved to the front when already known). Returns true when the set of
    /// domains changed.
    @discardableResult
    func record(_ newDomains: [String]) -> Bool {
        // Mail-provider and tracking domains are never recorded (TRIAGE D6).
        let cleaned = newDomains.map { $0.lowercased() }
            .filter { EmailDomains.isPlausibleDomain($0) && EmailDomains.isServiceDomain($0) }
        guard !cleaned.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let before = read()
        var merged: [String] = []
        for domain in cleaned + before where !merged.contains(domain) {
            merged.append(domain)
        }
        merged = Array(merged.prefix(Self.limit))
        if merged != before { write(merged) }
        // Only a different set of domains needs a new registration; order alone does not.
        return Set(merged) != Set(before)
    }

    private func read() -> [String] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    private func write(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Union of several sources, in order, without duplicates.
struct CompositeDomainSource: IdentityDomainSource {
    let sources: [any IdentityDomainSource]

    func domains() async -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for source in sources {
            for domain in await source.domains() {
                let key = domain.lowercased()
                if !key.isEmpty, seen.insert(key).inserted { result.append(key) }
            }
        }
        return result
    }
}

extension CompositeDomainSource {
    /// Bundled popular domains + demo site + domains seen in verification emails.
    static func standard(bundle: Bundle, seen: SeenDomainStore) -> CompositeDomainSource {
        CompositeDomainSource(sources: [FixedDomainSource(), BundledDomainSource(bundle: bundle), seen])
    }
}
