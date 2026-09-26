import Foundation

/// Light client-side check that typed text looks like an email address, used to enable Continue
/// and show the inline validation message. Not a full RFC 5322 parser: the provider / IMAP server
/// is the real authority, this only catches obvious typos.
enum EmailAddressFormat {
    /// `local@domain.tld`: exactly one "@", no whitespace, a non-empty local part, and a domain of
    /// at least two non-empty dot-separated labels whose last label has two or more letters.
    static func looksValid(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        guard !local.isEmpty else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }
}
