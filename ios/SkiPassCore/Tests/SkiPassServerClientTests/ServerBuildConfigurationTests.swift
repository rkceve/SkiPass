import Foundation
import SkiPassServerClient
import XCTest

/// The extension must not treat the Secrets.example placeholders as a real server (the same rule
/// as the app's `AppConfiguration`, applied to the extension through this type).
final class ServerBuildConfigurationTests: XCTestCase {
    func testRealValuesAreUsed() throws {
        let config = try XCTUnwrap(ServerBuildConfiguration(info: [
            "SkiPassServerURL": " https://skipass-server.vercel.app ",
            "SkiPassAppToken": "live-token",
        ]))
        XCTAssertEqual(config.baseURL.absoluteString, "https://skipass-server.vercel.app")
        XCTAssertEqual(config.appToken, "live-token")
    }

    func testExamplePlaceholdersMeanNotConfigured() {
        XCTAssertNil(ServerBuildConfiguration(info: [
            "SkiPassServerURL": "https://skipass.example.invalid",
            "SkiPassAppToken": "example-app-token",
        ]))
        XCTAssertNil(ServerBuildConfiguration(info: [
            "SkiPassServerURL": "https://skipass-server.vercel.app",
            "SkiPassAppToken": "example-app-token",
        ]))
        XCTAssertNil(ServerBuildConfiguration(info: [
            "SkiPassServerURL": "https://skipass.example.invalid",
            "SkiPassAppToken": "live-token",
        ]))
    }

    func testUnsetOrMalformedValuesMeanNotConfigured() {
        XCTAssertNil(ServerBuildConfiguration(info: [:]))
        XCTAssertNil(ServerBuildConfiguration(info: [
            "SkiPassServerURL": "$(SKIPASS_SERVER_URL)",
            "SkiPassAppToken": "$(SKIPASS_APP_TOKEN)",
        ]))
        XCTAssertNil(ServerBuildConfiguration(info: ["SkiPassServerURL": "", "SkiPassAppToken": "live-token"]))
        XCTAssertNil(ServerBuildConfiguration(info: ["SkiPassServerURL": "not a url", "SkiPassAppToken": "live-token"]))
        XCTAssertEqual(ServerBuildConfiguration.value("RevenueCatAPIKey", in: ["RevenueCatAPIKey": "appl_example"]), nil)
    }
}
