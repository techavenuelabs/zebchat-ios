import XCTest
@testable import ZebChat

final class BridgeTests: XCTestCase {
    private let page = URL(string: "https://cdn.zebchat.com/widget/v1/mobile.html")!

    // MARK: - Page → native guards (isMobilePageMessage)

    func testParsesEveryPageMessage() {
        XCTAssertEqual(MobilePageMessage.parse(#"{"type":"ready","v":1}"#), .ready)
        XCTAssertEqual(
            MobilePageMessage.parse(#"{"type":"renewed","token":"tok","expiresAt":"2026-10-08T12:00:00.000Z"}"#),
            .renewed(token: "tok", expiresAt: "2026-10-08T12:00:00.000Z")
        )
        XCTAssertEqual(MobilePageMessage.parse(#"{"type":"expired"}"#), .expired)
        XCTAssertEqual(MobilePageMessage.parse(#"{"type":"close","extra":true}"#), .close)
        XCTAssertEqual(
            MobilePageMessage.parse(#"{"type":"error","status":0,"message":""}"#),
            .error(status: 0, message: "")
        )
    }

    func testAcceptsAnAlreadyDecodedObject() {
        let body: [String: Any] = ["type": "error", "status": 403, "message": "app_not_allowed"]
        XCTAssertEqual(MobilePageMessage.parse(body), .error(status: 403, message: "app_not_allowed"))
    }

    func testRejectsReadyWithAnotherVersion() {
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"ready","v":2}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"ready","v":true}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"ready","v":"1"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"ready"}"#))
    }

    func testRejectsMalformedRenewed() {
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"renewed","token":"","expiresAt":"2026-10-08T12:00:00Z"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"renewed","token":"tok","expiresAt":"soon"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"renewed","token":42,"expiresAt":"2026-10-08T12:00:00Z"}"#))
        let long = String(repeating: "a", count: 4097)
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"renewed","token":"\#(long)","expiresAt":"2026-10-08T12:00:00Z"}"#))
    }

    func testRejectsMalformedError() {
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"error","status":1.5,"message":"x"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"error","status":"500","message":"x"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"error","status":500}"#))
        let long = String(repeating: "m", count: 501)
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"error","status":500,"message":"\#(long)"}"#))
    }

    func testIgnoresUnknownAndNonObjectMessages() {
        XCTAssertNil(MobilePageMessage.parse(#"{"type":"init","v":1}"#))
        XCTAssertNil(MobilePageMessage.parse(#"{"kind":"ready"}"#))
        XCTAssertNil(MobilePageMessage.parse(#"["ready"]"#))
        XCTAssertNil(MobilePageMessage.parse("not json"))
        XCTAssertNil(MobilePageMessage.parse(42))
    }

    // MARK: - Sender check

    func testTrustsOnlyTheMainFrameOfTheChatPageOrigin() {
        XCTAssertTrue(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "https", host: "cdn.zebchat.com", port: 0, pageURL: page))
        XCTAssertTrue(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "https", host: "CDN.zebchat.com", port: 443, pageURL: page))
        // The Turnstile iframe shares the web view.
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: false, scheme: "https", host: "cdn.zebchat.com", port: 0, pageURL: page))
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "https", host: "challenges.cloudflare.com", port: 0, pageURL: page))
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "http", host: "cdn.zebchat.com", port: 0, pageURL: page))
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "https", host: "cdn.zebchat.com", port: 8443, pageURL: page))
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "https", host: "", port: 0, pageURL: page))
    }

    func testExplicitPortMustMatch() {
        let local = URL(string: "http://localhost:5173/mobile.html")!
        XCTAssertTrue(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "http", host: "localhost", port: 5173, pageURL: local))
        XCTAssertFalse(MobileBridge.isTrustedSender(isMainFrame: true, scheme: "http", host: "localhost", port: 3000, pageURL: local))
    }

    // MARK: - Native → page

    func testInitScriptCarriesTheFullSessionAsAStringLiteral() throws {
        let session = StoredSession(
            token: "tok\"</script>\u{2028}",
            expiresAt: "2026-10-08T12:00:00.000Z",
            visitor: ZebChatVisitor(id: "vis_1", name: "Ana", email: nil, phone: nil, verified: true),
            user: nil
        )
        let script = try XCTUnwrap(MobileBridge.initScript(for: session))
        let prefix = "window.ZebChatBridge&&window.ZebChatBridge.receive("
        let suffix = ");true"
        XCTAssertTrue(script.hasPrefix(prefix))
        XCTAssertTrue(script.hasSuffix(suffix))
        let literal = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        let jsonText = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any])

        XCTAssertEqual(message["type"] as? String, "init")
        XCTAssertEqual(message["v"] as? Int, 1)
        XCTAssertEqual(message["token"] as? String, session.token)
        XCTAssertEqual(message["expiresAt"] as? String, session.expiresAt)
        let visitor = try XCTUnwrap(message["visitor"] as? [String: Any])
        XCTAssertEqual(visitor["id"] as? String, "vis_1")
        XCTAssertEqual(visitor["name"] as? String, "Ana")
        XCTAssertTrue(visitor["email"] is NSNull)
        XCTAssertTrue(visitor["phone"] is NSNull)
        XCTAssertEqual(visitor["verified"] as? Bool, true)
        XCTAssertNil(message["user"], "the native user (and its hash) never reaches the page")
    }

    func testPageURLCarriesSiteAppPlatformSdkAndLocale() throws {
        let url = try XCTUnwrap(MobileBridge.pageURL(
            base: URL(string: "https://cdn.zebchat.com/widget/v1/mobile.html?debug=1&locale=xx")!,
            siteKey: "zc_demo",
            appId: "com.example.app",
            sdk: "flutter/1.0.0",
            locale: "fr"
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        XCTAssertEqual(query["site"], "zc_demo")
        XCTAssertEqual(query["app"], "com.example.app")
        XCTAssertEqual(query["platform"], "ios")
        XCTAssertEqual(query["sdk"], "flutter/1.0.0")
        XCTAssertEqual(query["locale"], "fr")
        XCTAssertEqual(query["debug"], "1")
        XCTAssertEqual(items.filter { $0.name == "locale" }.count, 1)
        XCTAssertEqual(url.host, "cdn.zebchat.com")
        XCTAssertEqual(url.path, "/widget/v1/mobile.html")
    }
}
