//
//  OTPParser.swift
//  SkiPassExtraction
//
//  Ported from SoFriendly/2fhey (TwoFHey), file TwoFHey/OTPParser/OTPParser.swift,
//  commit 76a3c02df52ea98bba5263233ec337823310df07 — CC0-1.0.
//  https://github.com/SoFriendly/2fhey/blob/76a3c02df52ea98bba5263233ec337823310df07/TwoFHey/OTPParser/OTPParser.swift
//  License text: Resources/THIRD_PARTY_2FHEY.txt. Pattern files: Resources/*.json (copied unmodified).
//
//  Changes from upstream:
//  - Removed macOS-only parts: `import AppKit`, `ParsedOTP.copyToClipboard()` (NSPasteboard).
//  - Removed the runtime pattern refresh from GitHub, the Caches-directory copy and its
//    app-version invalidation (upstream L59-77, L102-151): an AutoFill extension must not
//    download code at fill time. Patterns load only from this module's bundle (`Bundle.module`).
//  - The configuration is loaded once and immutable, so the lock is gone and the type is Sendable.
//  - Added `Mode` for email input (SkiPass additions, each marked below: extra forbidden
//    zones, own-line rule for the unanchored fallback, no short-keyword match inside a word).
//    `.message` is the upstream behavior unchanged.
//  - SkiPass additions (TRIAGE D13): `Resources/ja.json` (SkiPass-authored Japanese keywords and an
//    anchored pattern, not from upstream), full-width digits returned as ASCII, and `EmailGuard`
//    zones for promotional / coupon codes and Japanese order or member numbers.
//
//  Upstream description: extracts one-time codes from message text. Every candidate code
//  must survive the NumberGuard, which rejects anything that looks like a phone number,
//  the sender's own number, money, a time, or a date.
//

import Foundation

struct ParsedOTP: Equatable, Sendable {
    let service: String?
    let code: String
}

final class OTPParser: Sendable {
    /// Which kind of text is parsed. SkiPass addition; upstream only knows `.message`.
    enum Mode: Sendable {
        /// Upstream 2FHey behavior (SMS / notification text).
        case message
        /// Email subject: upstream behavior plus `EmailGuard` forbidden zones.
        case emailSubject
        /// Email body: `EmailGuard` forbidden zones, and the unanchored fallback (upstream
        /// step 3b) only accepts a token that stands alone on its own line.
        case emailBody
    }

    private struct LanguageFile: Codable {
        let keywords: [String]
        let patterns: [String]
    }

    private struct CustomPatternsFile: Codable {
        struct Entry: Codable {
            let service: String
            let pattern: String
        }
        let customPatterns: [Entry]
    }

    struct Configuration: Sendable {
        var keywords: [String] = []
        var languagePatterns: [NSRegularExpression] = []
        var customPatterns: [(service: String, regex: NSRegularExpression)] = []
    }

    private static let languageFiles = ["en.json", "fr.json", "zh.json", "es.json", "de.json", "pt.json", "he.json",
                                        "ja.json"] // ja.json: SkiPass addition (TRIAGE D13)
    private static let customPatternsFile = "custom-patterns.json"

    /// Shared instance; the bundled pattern files are parsed once.
    static let shared = OTPParser()

    let configuration: Configuration

    init(bundle: Bundle = .module) {
        configuration = Self.loadConfiguration(bundle: bundle)
    }

    // MARK: - Pattern loading

    private static func loadConfiguration(bundle: Bundle) -> Configuration {
        var config = Configuration()
        for fileName in languageFiles {
            guard let data = fileData(fileName, bundle: bundle),
                  let file = try? JSONDecoder().decode(LanguageFile.self, from: data) else { continue }
            config.keywords.append(contentsOf: file.keywords.map { $0.lowercased() })
            config.languagePatterns.append(contentsOf: file.patterns.compactMap {
                try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
            })
        }
        if let data = fileData(customPatternsFile, bundle: bundle),
           let file = try? JSONDecoder().decode(CustomPatternsFile.self, from: data) {
            config.customPatterns = file.customPatterns.compactMap { entry in
                (try? NSRegularExpression(pattern: entry.pattern)).map { (entry.service, $0) }
            }
        }
        return config
    }

    private static func fileData(_ fileName: String, bundle: Bundle) -> Data? {
        let resource = (fileName as NSString).deletingPathExtension
        let url = bundle.url(forResource: resource, withExtension: "json", subdirectory: "OTPKeywords")
            ?? bundle.url(forResource: resource, withExtension: "json")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    /// Parses a message body for a one-time code. `sender` (a handle, phone number,
    /// or notification title) is never searched for codes — it is only used to make
    /// sure the sender's own number is never returned.
    func parse(_ text: String, sender: String? = nil, mode: Mode = .message) -> ParsedOTP? {
        let config = configuration
        let senderDigits = sender.map { String($0.filter(\.isNumber)) } ?? ""
        let emailGuard = mode != .message // SkiPass addition

        // 1. Service-specific patterns are the most precise signal we have.
        let fullGuard = NumberGuard(text: text, senderDigits: senderDigits, email: emailGuard)
        for (service, regex) in config.customPatterns {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            for group in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                let code = Self.normalize(text[range])
                if Self.isPlausibleCode(code, allowLongNumeric: true), fullGuard.allows(range, code: code) {
                    return ParsedOTP(service: service.lowercased(), code: code)
                }
            }
        }

        // 2. Google's G-XXXXX format. The G- prefix can't be part of a phone number.
        if let range = Self.googlePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap({ Range($0.range(at: 1), in: text) }) {
            return ParsedOTP(service: "google", code: String(text[range]))
        }

        // 3. Everything below requires an OTP keyword somewhere in the message.
        let lowercased = text.lowercased()
        guard config.keywords.contains(where: lowercased.contains) else { return nil }

        // URLs are stripped so their path segments can't be mistaken for codes.
        let searchText = Self.stripURLs(from: text)
        let guarded = NumberGuard(text: searchText, senderDigits: senderDigits, email: emailGuard)
        let service = extractService(from: lowercased, keywords: config.keywords)

        // 3a. Anchored language patterns ("code is 123456", "验证码：123456", ...).
        for pattern in config.languagePatterns {
            let matches = pattern.matches(in: searchText, range: NSRange(searchText.startIndex..., in: searchText))
            for match in matches where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: searchText) else { continue }
                if mode != .message, let whole = Range(match.range, in: searchText),
                   Self.startsInsideWordWithShortKeyword(whole, in: searchText) { continue } // SkiPass addition
                let code = Self.normalize(searchText[range])
                if code.contains(where: \.isNumber), Self.isPlausibleCode(code), guarded.allows(range, code: code) {
                    return ParsedOTP(service: service, code: code)
                }
            }
        }

        // 3b. Fallback: standalone tokens in order of appearance — plain digit runs,
        // spaced/dashed 3+3 groups, and mixed alphanumeric tokens.
        for pattern in Self.fallbackPatterns {
            let matches = pattern.matches(in: searchText, range: NSRange(searchText.startIndex..., in: searchText))
            for match in matches {
                guard let range = Range(match.range(at: 1), in: searchText) else { continue }
                // SkiPass addition: an email body is long prose (newsletters, receipts,
                // footers), so an unanchored token only counts when it is alone on its line,
                // which is how verification emails lay out the code.
                if mode == .emailBody, !Self.isAloneOnLine(range, in: searchText) { continue }
                let code = Self.normalize(searchText[range])
                if Self.isPlausibleCode(code), guarded.allows(range, code: code) {
                    return ParsedOTP(service: service, code: code)
                }
            }
        }

        return nil
    }

    // MARK: - Candidate validation

    /// Collapses a raw match to its alphanumeric characters (drops spaces/dashes/newlines).
    /// SkiPass addition: full-width characters (common in Japanese mail, e.g. "１２３４５６") become
    /// their ASCII forms, which is what the user would type.
    private static func normalize(_ raw: Substring) -> String {
        let joined = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return joined.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? joined
    }

    /// A plausible code is 4-8 digits, or 4-10 characters when mixed with letters.
    /// Purely numeric strings longer than 8 digits look like phone/account numbers,
    /// so only explicitly whitelisted custom patterns may return them.
    private static func isPlausibleCode(_ code: String, allowLongNumeric: Bool = false) -> Bool {
        guard code.count >= 4, code.count <= 10, code.contains(where: \.isNumber) else { return false }
        if code.allSatisfy(\.isNumber) && !allowLongNumeric {
            return code.count <= 8
        }
        return true
    }

    /// SkiPass addition: true when the line holding `range` contains nothing else.
    private static func isAloneOnLine(_ range: Range<String.Index>, in text: String) -> Bool {
        let line = text[text.lineRange(for: range)].trimmingCharacters(in: .whitespacesAndNewlines)
        return line == text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SkiPass addition (email modes): the anchored patterns have no leading word boundary,
    /// so short keywords ("use", "pin", "otp") also match inside words, e.g. "Mouse M185"
    /// → "use M185". A match is dropped when it starts right after an ASCII letter and its
    /// leading ASCII-letter run is shorter than 4. Longer keywords stay allowed mid-word so
    /// compounds such as "Sicherheitscode: 123456" still match; CJK/Hebrew are unaffected.
    private static func startsInsideWordWithShortKeyword(_ match: Range<String.Index>, in text: String) -> Bool {
        guard match.lowerBound > text.startIndex else { return false }
        let previous = text[text.index(before: match.lowerBound)]
        guard previous.isASCII, previous.isLetter else { return false }
        return text[match].prefix(while: { $0.isASCII && $0.isLetter }).count < 4
    }

    private static let googlePattern = try! NSRegularExpression(pattern: #"\b(G-[A-Z0-9]{5,8})\b"#)

    private static let fallbackPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\b(\d{4,8})\b"#),
        try! NSRegularExpression(pattern: #"\b(\d{3}[\s\-]\d{3})\b"#),
        try! NSRegularExpression(pattern: #"\b([A-Za-z0-9]*\d[A-Za-z0-9]*)\b"#),
    ]

    private static let urlPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"https?://\S+"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"[a-zA-Z0-9][-a-zA-Z0-9]*(?:\.[a-zA-Z0-9][-a-zA-Z0-9]*)+/\S*"#),
    ]

    private static func stripURLs(from text: String) -> String {
        urlPatterns.reduce(text) { result, pattern in
            pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
    }

    // MARK: - Service name extraction (best effort)

    private static let knownServices = [
        "td ameritrade", "coinbase", "ally", "schwab", "id.me", "bofa", "wise.com", "paypal",
        "venmo", "verizon", "kotak bank", "weibo", "wechat", "whatsapp", "viber", "snapchat",
        "slack", "signal", "telegram", "kakaotalk", "skype", "facebook", "microsoft", "google",
        "twitter", "instagram", "sony", "apple", "ubereats", "uber", "lyft", "postmates",
        "doordash", "chipotle", "amazon", "tencent", "alibaba", "taobao", "baidu", "yandex",
        "ebay", "intel", "cisco", "oracle", "ibm", "foursquare", "hotmail", "outlook", "yahoo",
        "netflix", "spotify", "nike", "adidas", "shopify", "wordpress", "yelp", "grubhub",
        "seamless", "github", "flickr", "etsy", "bank of america", "zocdoc", "twilio", "xbox",
        "kayak", "grab", "moonpay", "robinhood", "cater allen", "apple pay", "bill.com", "amex",
        "fanduel", "ca dmv", "chase", "digitalocean", "geico", "dbs bank", "onelogin", "usps",
        "migov", "pf-bank", "vodafone", "mygov", "bforbank", "idcat mobil", "revolut",
        "fnz bank", "sofi", "aeroplan", "truist", "link",
    ]

    private static let commonWords: Set<String> = [
        "your", "the", "this", "that", "here", "use", "enter", "please", "not", "share",
        "will", "valid", "only", "sent", "ton", "vous", "votre", "une", "des", "ici",
        "utilisez", "entrez", "merci", "pas", "uniquement", "seulement", "partagez", "sera",
    ]

    private static let servicePatterns: [NSRegularExpression] = [
        #"^\[([^\]\d]{3,})\]"#,
        #"^\(([^)\d]{3,})\)"#,
        #"^welcome\s+to\s+([\w ]{4,}?)[\s,;.]"#,
        #"from\s+([a-z0-9 ]+?)(?:\s|$)"#,
        #"(?:verification|code|otp|pin)\s+(?:for|from)\s+([a-z0-9 ]+?)(?:\s|$)"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private func extractService(from lowercased: String, keywords: [String]) -> String? {
        if let known = Self.knownServices.first(where: lowercased.contains) {
            return known
        }
        for pattern in Self.servicePatterns {
            guard let match = pattern.firstMatch(in: lowercased, range: NSRange(lowercased.startIndex..., in: lowercased)),
                  let range = Range(match.range(at: 1), in: lowercased) else { continue }
            let service = lowercased[range].trimmingCharacters(in: .whitespaces)
            if service.count > 2, !keywords.contains(service), !Self.commonWords.contains(service) {
                return service
            }
        }
        return nil
    }
}

// MARK: - NumberGuard

/// Identifies every range of a message that must never be treated as a code:
/// phone numbers in any common format, numbers being dialed or texted, money,
/// decimals, times, dates, and ordinals. Also rejects any candidate whose digits
/// appear in the sender's own number.
private struct NumberGuard {
    private static let forbiddenPatterns: [NSRegularExpression] = [
        // International numbers: +1 415 555 2671, +447911123456, ...
        #"\+\d[\d\s().\-]{5,}\d"#,
        // NANP: 555-123-4567, (555) 123-4567, 555.123.4567
        #"\(?\b\d{3}\)?[-. ]\d{3}[-. ]\d{4}\b"#,
        // Seven-digit local numbers: 555-1234
        #"\b\d{3}[-.]\d{4}\b"#,
        // Digit runs too long to be codes (account and phone numbers).
        #"\d{9,}"#,
        // Numbers you're told to call or text are contact numbers, not codes.
        #"(?i)\b(?:call|text|dial|sms|fax)\b[^\d\n]{0,20}[+(]?\d[\d ().\-]*"#,
        // Money, decimals, times, meridiem times, ordinals, and dates.
        #"[$€£₹¥]\s?\d[\d,.]*"#,
        #"\b\d+[.,]\d+\b"#,
        #"\b\d{1,2}:\d{2}\b"#,
        #"(?i)\b\d+\s?(?:am|pm)\b"#,
        #"(?i)\b\d+(?:st|nd|rd|th)\b"#,
        #"\b\d{1,4}[-/]\d{1,2}[-/]\d{1,4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// SkiPass addition (email only): identifiers that emails label explicitly
    /// (order/invoice/booking numbers, "confirmation number") and copyright years.
    /// "confirmation code" is not matched: only number/no/#/id labels are.
    private static let emailForbiddenPatterns: [NSRegularExpression] = [
        #"(?i)\b(?:order|invoice|receipt|tracking|shipment|package|reference|ref|account|acct|customer|member(?:ship)?|ticket|case|booking|reservation|transaction|confirmation|policy|claim)\s*(?:number\b|num\b|no\b\.?|#|id\b)\s*[:#.]?\s*[A-Za-z0-9][A-Za-z0-9-]*"#,
        #"(?i)\b(?:order|invoice)\s*[:#]?\s*\d[\d-]*"#,
        #"(?i)(?:©|\(c\)|copyright)\s*(?:\d{4}\s*[-–]\s*)?\d{4}"#,
        // TRIAGE D13: promotional codes are not one-time codes. A code labelled as a promo /
        // coupon / discount / voucher / gift / referral / reward code, a token followed by
        // "at checkout", the token right after "at checkout:", and a line offering "N% off".
        #"(?i)\b(?:promo(?:tion(?:al)?)?|coupon|discount|voucher|gift(?:\s*card)?|referral|reward)s?\s*(?:code|card)?\s*(?:is\b|:)?\s*[A-Za-z0-9][A-Za-z0-9-]*"#,
        #"(?i)\b[A-Za-z0-9][A-Za-z0-9-]*\s+(?:at|during)\s+checkout\b"#,
        #"(?i)\b(?:at|during)\s+checkout\b[^A-Za-z0-9]{0,20}[A-Za-z0-9][A-Za-z0-9-]*"#,
        #"(?i)[^\n]*\b\d+\s*%\s*off\b[^\n]*"#,
        // TRIAGE D13: Japanese order / reservation / member / inquiry numbers, dates and prices.
        #"(?:注文|予約)(?:確認)?番号[^0-9０-９\n]{0,6}[0-9０-９][0-9０-９-]*"#,
        #"(?:会員|お客様|顧客|受付|問い?合わ?せ|伝票|追跡|請求|口座)番号[^0-9０-９\n]{0,6}[0-9０-９][0-9０-９-]*"#,
        #"[0-9０-９]{2,4}\s*年\s*[0-9０-９]{1,2}\s*月(?:\s*[0-9０-９]{1,2}\s*日)?"#,
        #"[0-9０-９][0-9０-９,，]*\s*円"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private let forbidden: [Range<String.Index>]
    private let senderDigits: String

    init(text: String, senderDigits: String, email: Bool = false) {
        self.senderDigits = senderDigits
        let fullRange = NSRange(text.startIndex..., in: text)
        let patterns = email ? Self.forbiddenPatterns + Self.emailForbiddenPatterns : Self.forbiddenPatterns
        forbidden = patterns.flatMap { pattern in
            pattern.matches(in: text, range: fullRange).compactMap { match -> Range<String.Index>? in
                guard let range = Range(match.range, in: text) else { return nil }
                // Extend forbidden zones through digits touching either end of the
                // match, so fragments of long numbers can't slip out either side.
                return Self.extend(range, in: text)
            }
        }
    }

    private static func extend(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        while lower > text.startIndex, text[text.index(before: lower)].isNumber {
            lower = text.index(before: lower)
        }
        var upper = range.upperBound
        while upper < text.endIndex, text[upper].isNumber {
            upper = text.index(after: upper)
        }
        return lower..<upper
    }

    func allows(_ range: Range<String.Index>, code: String) -> Bool {
        if forbidden.contains(where: { $0.overlaps(range) }) { return false }
        let digits = String(code.filter(\.isNumber))
        if digits.count >= 4, senderDigits.contains(digits) { return false }
        return true
    }
}
