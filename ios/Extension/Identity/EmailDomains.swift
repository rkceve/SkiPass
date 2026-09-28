import Foundation
import SkiPassModels

/// Domain helpers shared by identity registration (app + extension) and the extension's
/// local judge fallback.
enum EmailDomains {

    /// Registrable domain (eTLD+1) of a service identifier or host, lowercased; nil for an
    /// empty value. Accepts a bare host, a URL, or `host:port`. IP addresses and single-label
    /// hosts are returned as-is (like `tldts` `getHostname`).
    ///
    /// Hosts under a two-label public suffix (`PublicSuffixes.twoLabel`: ICANN second-level suffixes
    /// plus PaaS suffixes of the PSL private section) keep three labels, the rest keep two. The server
    /// uses `tldts.getDomain` with `allowPrivateDomains: true`, so `skipass-demo.vercel.app`
    /// stays `skipass-demo.vercel.app` on both sides.
    static func registrableDomain(_ service: String) -> String? {
        guard let host = hostname(service) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !isIPv4(host) else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if PublicSuffixes.twoLabel.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Registrable domains of mail senders, mail providers and click-tracking hosts: they appear in
    /// verification emails but are not the site the code is for, so they never become identities.
    static let nonServiceDomains: Set<String> = [
        // Sending / email service providers.
        "resend.dev", "resend.com", "sendgrid.net", "sendgrid.com", "mailgun.org", "mailgun.net",
        "amazonses.com", "mandrillapp.com", "mailchimp.com", "mailchimpapp.net", "mcsv.net",
        "mcusercontent.com", "list-manage.com", "sparkpostmail.com", "sparkpost.com", "postmarkapp.com",
        "mailjet.com", "mjt.lu", "sendinblue.com", "brevo.com", "sibmail.com", "exacttarget.com",
        "createsend.com", "cmail19.com", "cmail20.com", "rs6.net", "constantcontact.com",
        "hubspotemail.net", "hubspotlinks.com", "hs-analytics.net", "klaviyomail.com", "klclick.com",
        "customeriomail.com", "mlsend.com", "emltrk.com", "awstrack.me", "sailthru.com",
        "urldefense.com",
        // Mailbox providers (a sender or contact address, not the site).
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "aol.com", "proton.me",
        "protonmail.com", "gmx.com", "gmx.net", "zoho.com",
    ]

    /// False for the provider / tracking domains in `nonServiceDomains`.
    static func isServiceDomain(_ domain: String) -> Bool {
        !nonServiceDomains.contains(domain.lowercased())
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
    /// hosts of `http(s)` links in the body text, without mail-provider and tracking domains.
    /// Sorted, without duplicates.
    static func domains(in message: FetchedMessage) -> [String] {
        var found = Set<String>()
        if let sender = senderDomain(message.from), let domain = registrableDomain(sender) {
            found.insert(domain)
        }
        for host in linkHosts(in: message.bodyText) {
            if let domain = registrableDomain(host) { found.insert(domain) }
        }
        return found.filter { isPlausibleDomain($0) && isServiceDomain($0) }.sorted()
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
