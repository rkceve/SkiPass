import Foundation
import SkiPassModels

/// Domain helpers shared by identity registration (app + extension) and the extension's
/// local judge fallback.
enum EmailDomains {

    /// Two-label public suffixes (ICANN section of the Public Suffix List) under which the
    /// registrable domain has three labels. The server uses the full list through `tldts`
    /// (`getDomain`, ICANN rules only: server/src/jev.ts `registrableDomain`); this is the subset
    /// that occurs in common sign-in mail. Hosts under any other suffix use the last two labels.
    // OPEN(domains): a bundled full Public Suffix List would match the server exactly.
    static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "net.nz",
        "com.br", "net.br", "org.br",
        "com.cn", "net.cn", "org.cn",
        "com.tw", "org.tw", "com.hk", "org.hk",
        "co.kr", "or.kr", "co.in", "net.in", "org.in",
        "com.mx", "com.sg", "com.my", "co.za", "co.id", "co.th", "com.tr", "com.ar",
    ]

    /// Registrable domain (eTLD+1) of a service identifier or host, lowercased; nil for an
    /// empty value. Accepts a bare host, a URL, or `host:port`. IP addresses and single-label
    /// hosts are returned as-is (like `tldts` `getHostname`).
    static func registrableDomain(_ service: String) -> String? {
        guard let host = hostname(service) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !isIPv4(host) else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Lowercased host of a bare host or URL, without port, userinfo or trailing dot.
    static func hostname(_ value: String) -> String? {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("://"), let host = URL(string: s)?.host(), !host.isEmpty {
            s = host
        } else {
            if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
            if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
            if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// Registrable domains a verification email points at: the sender's address domain and the
    /// hosts of `http(s)` links in the body text. Sorted, without duplicates.
    static func domains(in message: FetchedMessage) -> [String] {
        var found = Set<String>()
        if let sender = senderDomain(message.from), let domain = registrableDomain(sender) {
            found.insert(domain)
        }
        for host in linkHosts(in: message.bodyText) {
            if let domain = registrableDomain(host) { found.insert(domain) }
        }
        return found.filter(isPlausibleDomain).sorted()
    }

    /// Domain part of a `From` value such as `Acme <no-reply@mail.acme.com>` or `a@b.com`.
    static func senderDomain(_ from: String) -> String? {
        var address = from
        if let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
            address = String(from[from.index(after: open)..<close])
        }
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'>").union(.whitespacesAndNewlines))
        return domain.isEmpty ? nil : domain.lowercased()
    }

    /// Hosts of `http://` / `https://` URLs found in plain text.
    static func linkHosts(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host(), !host.isEmpty
            else { return nil }
            return host.lowercased()
        }
    }

    /// At least two labels, letters/digits/hyphens only, not an IPv4 address.
    static func isPlausibleDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !isIPv4(domain) else { return false }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            !label.isEmpty && label.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
