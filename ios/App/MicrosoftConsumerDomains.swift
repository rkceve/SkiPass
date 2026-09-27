import Foundation

/// Microsoft consumer (Outlook.com) mail domains. Addresses here sign in through Microsoft's
/// official page: Outlook.com no longer accepts passwords over IMAP (basic auth removed 2024-09-16).
/// Source: Spam Resource "Microsoft OLC/Hotmail domains list" (2025-01), every row typed
/// "Microsoft OLC/Outlook.com/Hotmail"
/// (https://www.spamresource.com/2025/01/microsoft-olchotmail-domains-list.html), plus msn.co.jp.
enum MicrosoftConsumerDomains {
    static let all: Set<String> = [
        "hotmail.ac", "hotmail.as", "hotmail.at", "hotmail.ba", "hotmail.bb", "hotmail.be",
        "hotmail.bs", "hotmail.ca", "hotmail.ch", "hotmail.cl", "hotmail.co.at", "hotmail.co.id",
        "hotmail.co.il", "hotmail.co.in", "hotmail.co.jp", "hotmail.co.kr", "hotmail.co.nz", "hotmail.co.pn",
        "hotmail.co.th", "hotmail.co.ug", "hotmail.co.uk", "hotmail.co.ve", "hotmail.co.za", "hotmail.com",
        "hotmail.com.ar", "hotmail.com.au", "hotmail.com.bo", "hotmail.com.br", "hotmail.com.do", "hotmail.com.hk",
        "hotmail.com.ly", "hotmail.com.my", "hotmail.com.ph", "hotmail.com.pl", "hotmail.com.ru", "hotmail.com.sg",
        "hotmail.com.tr", "hotmail.com.tt", "hotmail.com.tw", "hotmail.com.uz", "hotmail.com.ve", "hotmail.com.vn",
        "hotmail.de", "hotmail.dk", "hotmail.ee", "hotmail.es", "hotmail.fi", "hotmail.fr",
        "hotmail.gr", "hotmail.hk", "hotmail.hu", "hotmail.ie", "hotmail.it", "hotmail.jp",
        "hotmail.la", "hotmail.lt", "hotmail.lu", "hotmail.lv", "hotmail.ly", "hotmail.mn",
        "hotmail.mw", "hotmail.my", "hotmail.net.fj", "hotmail.no", "hotmail.ph", "hotmail.pn",
        "hotmail.pt", "hotmail.rs", "hotmail.se", "hotmail.sg", "hotmail.sh", "hotmail.sk",
        "hotmail.ua", "hotmail.vu", "live.at", "live.be", "live.ca", "live.ch",
        "live.cl", "live.cn", "live.co.in", "live.co.kr", "live.co.uk", "live.co.za",
        "live.com", "live.com.ar", "live.com.au", "live.com.co", "live.com.mx", "live.com.my",
        "live.com.pe", "live.com.ph", "live.com.pk", "live.com.pt", "live.com.sg", "live.com.ve",
        "live.de", "live.dk", "live.fi", "live.fr", "live.hk", "live.ie",
        "live.in", "live.it", "live.jp", "live.nl", "live.no", "live.ph",
        "live.ru", "live.se", "msn.co.jp", "msn.com", "msn.nl", "outlook.at",
        "outlook.be", "outlook.bg", "outlook.bz", "outlook.cl", "outlook.cm", "outlook.co",
        "outlook.co.cr", "outlook.co.id", "outlook.co.il", "outlook.co.nz", "outlook.co.th", "outlook.com",
        "outlook.com.ar", "outlook.com.au", "outlook.com.br", "outlook.com.es", "outlook.com.gr", "outlook.com.hr",
        "outlook.com.pe", "outlook.com.py", "outlook.com.tr", "outlook.com.ua", "outlook.com.vn", "outlook.cz",
        "outlook.de", "outlook.dk", "outlook.ec", "outlook.es", "outlook.fr", "outlook.hn",
        "outlook.ht", "outlook.hu", "outlook.ie", "outlook.in", "outlook.it", "outlook.jp",
        "outlook.kr", "outlook.la", "outlook.lv", "outlook.mx", "outlook.my", "outlook.pa",
        "outlook.ph", "outlook.pk", "outlook.pt", "outlook.ro", "outlook.sa", "outlook.sg",
        "outlook.si", "outlook.sk", "outlook.uy", "passport.com", "webtv.net", "windowslive.com",
        "windowslive.es",
    ]
}
