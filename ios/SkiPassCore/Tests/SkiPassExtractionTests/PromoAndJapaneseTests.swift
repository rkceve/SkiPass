import XCTest
import SkiPassModels
import SkiPassExtraction

/// Coupon / promo codes are not one-time codes, and Japanese verification
/// emails are recognised. Texts follow the layout of real mails; service names are placeholders.
final class PromoCodeTests: XCTestCase {
    private let extractor = OTPCodeExtractor()

    private func code(subject: String, body: String) -> String? {
        extractor.extractCode(from: FetchedMessage(
            id: "00000000-0000-0000-0000-000000000000:1", mailboxAddress: "user@example.com",
            from: "Acme Store <news@store.acme.example>", to: "user@example.com", subject: subject,
            date: Date(timeIntervalSince1970: 1_790_000_000), bodyText: body))
    }

    func testUseCodeAtCheckoutIsNotACode() {
        XCTAssertNil(code(subject: "Use code SAVE20 at checkout",
                          body: "Our fall sale is here. Use code SAVE20 at checkout for 20% off everything."))
    }

    func testPromoCodeLabelIsNotACode() {
        XCTAssertNil(code(subject: "A gift for you", body: "Your promo code: SPRING25\nValid until Sunday."))
        XCTAssertNil(code(subject: "Welcome!", body: "Coupon code WELCOME10 expires Sunday."))
        XCTAssertNil(code(subject: "Thanks for your order", body: "Your discount code is TAKE15 for your next visit."))
        XCTAssertNil(code(subject: "Happy birthday", body: "Your gift card code is GC7K2M9P."))
    }

    func testPercentOffOfferIsNotACode() {
        XCTAssertNil(code(subject: "Last chance", body: "Get 20% off your next order with code FALL20."))
        XCTAssertNil(code(subject: "20% off everything: use code FALL20", body: ""))
    }

    func testCodeAloneOnItsLineAfterCheckoutCueIsNotACode() {
        XCTAssertNil(code(subject: "Your exclusive offer",
                          body: "Thanks for being a member.\nUse this code at checkout:\n\nSAVE20\n\nSee terms online."))
    }

    func testVerificationCodeWithPromoFooterStillFound() {
        XCTAssertEqual(code(subject: "Your Acme verification code",
                            body: "Your verification code is 482913.\n\nShop now and get 15% off with code SAVE15."),
                       "482913")
    }
}

final class JapaneseVerificationEmailTests: XCTestCase {
    private let extractor = OTPCodeExtractor()

    private func code(subject: String, body: String) -> String? {
        extractor.extractCode(from: FetchedMessage(
            id: "00000000-0000-0000-0000-000000000000:1", mailboxAddress: "user@example.jp",
            from: "Acme <no-reply@acme.example.jp>", to: "user@example.jp", subject: subject,
            date: Date(timeIntervalSince1970: 1_790_000_000), bodyText: body))
    }

    func testNinshoCodeWithFullWidthColon() {
        let body = """
        Acme会員 様

        いつもAcmeをご利用いただきありがとうございます。
        ログインのための認証コードをお送りします。

        認証コード：482913

        ※認証コードの有効期限は発行から30分です。
        ※本メールは送信専用です。ご返信いただいてもお答えできません。
        """
        XCTAssertEqual(code(subject: "【Acme】認証コードのお知らせ", body: body), "482913")
    }

    func testKakuninCodeHaDesu() {
        XCTAssertEqual(code(subject: "Acmeアカウントの確認コード",
                            body: "確認コードは 739204 です。\nこのコードの有効期限は10分間です。"),
                       "739204")
    }

    func testOneTimePasswordAloneOnItsLine() {
        let body = """
        ワンタイムパスワード（OTP）をお知らせします。

        281947

        有効期限：2026年9月27日 15:30
        お心当たりのない場合は、至急お問い合わせください。
        お問い合わせ：0120-123-456
        """
        XCTAssertEqual(code(subject: "【Acme銀行】ワンタイムパスワードのお知らせ", body: body), "281947")
    }

    func testOneTimePasswordInSubject() {
        XCTAssertEqual(code(subject: "ワンタイムパスワード：604817（Acme銀行）", body: ""), "604817")
    }

    func testNinshoBangoInBrackets() {
        XCTAssertEqual(code(subject: "認証番号のお知らせ",
                            body: "Acmeで利用する認証番号は「5831」です。他人には教えないでください。"),
                       "5831")
    }

    func testSecurityCodeWithFullWidthDigitsIsReturnedAsASCII() {
        XCTAssertEqual(code(subject: "Acmeからのお知らせ", body: "セキュリティコード：１２３４５６\n10分以内に入力してください。"),
                       "123456")
    }

    func testPasscodeAndKenshoCode() {
        XCTAssertEqual(code(subject: "ログイン", body: "Acmeログイン用のパスコード: 90412"), "90412")
        XCTAssertEqual(code(subject: "メールアドレスの確認", body: "検証コード【318274】を画面に入力してください。"), "318274")
    }

    func testCampaignMailWithKeywordButNoCode() {
        let body = """
        認証コードの入力なしでログインできるようになりました。

        キャンペーン期間：2026年9月1日〜9月30日
        会員番号：12345678
        お問い合わせ：03-1234-5678
        """
        XCTAssertNil(code(subject: "【Acme】9月のお得なキャンペーン", body: body))
    }

    func testOrderConfirmationNumberIsNotACode() {
        let body = """
        ご注文ありがとうございます。
        ご注文確認番号：12345678
        お届け予定日：2026年9月30日
        """
        XCTAssertNil(code(subject: "【Acmeストア】ご注文の確認", body: body))
    }
}
