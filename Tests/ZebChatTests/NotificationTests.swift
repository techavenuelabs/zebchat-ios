import XCTest
@testable import ZebChat

final class NotificationTests: XCTestCase {
    private let push: [AnyHashable: Any] = [
        "zebchat": "1",
        "conversationId": "conv_0192",
        "siteKey": "zc_demo",
        "title": "Olivia",
        "body": "Hi! How can I help?",
        "aps": ["alert": ["title": "Olivia", "body": "Hi! How can I help?"], "badge": 2] as [String: Any],
        "gcm.message_id": "123",
    ]

    func testRecognizesZebChatPushes() {
        XCTAssertEqual(
            NotificationPayload(userInfo: push, expectedSiteKey: nil),
            NotificationPayload(userInfo: ["zebchat": "1", "conversationId": "conv_0192", "siteKey": "zc_demo"], expectedSiteKey: nil)
        )
        XCTAssertNotNil(NotificationPayload(userInfo: push, expectedSiteKey: "zc_demo"))
        // Flutter hands over [String: String].
        let fromFlutter: [String: String] = ["zebchat": "1", "conversationId": "conv_1", "siteKey": "zc_demo"]
        XCTAssertNotNil(NotificationPayload(userInfo: fromFlutter, expectedSiteKey: nil))
        XCTAssertNotNil(NotificationPayload(userInfo: ["zebchat": 1, "conversationId": "c", "siteKey": "zc_demo"], expectedSiteKey: nil))
    }

    func testRejectsOtherPushes() {
        XCTAssertNil(NotificationPayload(userInfo: push, expectedSiteKey: "zc_other"))
        XCTAssertNil(NotificationPayload(userInfo: ["aps": ["alert": "Sale!"]], expectedSiteKey: nil))
        XCTAssertNil(NotificationPayload(userInfo: ["zebchat": "0", "conversationId": "c", "siteKey": "zc_demo"], expectedSiteKey: nil))
        XCTAssertNil(NotificationPayload(userInfo: ["zebchat": true, "conversationId": "c", "siteKey": "zc_demo"], expectedSiteKey: nil))
        XCTAssertNil(NotificationPayload(userInfo: ["zebchat": "1", "siteKey": "zc_demo"], expectedSiteKey: nil))
        XCTAssertNil(NotificationPayload(userInfo: ["zebchat": "1", "conversationId": "c", "siteKey": "nope"], expectedSiteKey: nil))
    }

    func testPublicHelpersWorkBeforeConfigure() {
        // Tests never call configure, so every public call must be a safe no-op.
        XCTAssertNil(ZebChat.client)
        XCTAssertTrue(ZebChat.isZebChatNotification(push))
        XCTAssertFalse(ZebChat.isZebChatNotification(["aps": [:] as [String: Any]]))
        XCTAssertTrue(ZebChat.notificationReceived(push))
        ZebChat.setUser(ZebChatUser(id: "42", hash: "abc"))
        ZebChat.logout()
        ZebChat.trackScreen("Home")
        ZebChat.track("checkout_started")
        ZebChat.setPushToken("fcm")
        ZebChat.setLocale("fr")
        XCTAssertFalse(ZebChat.isChatVisible)
        XCTAssertNil(ZebChat.client)
    }

    func testLocaleValidation() {
        XCTAssertTrue(ZebChat.isLocale("auto"))
        XCTAssertTrue(ZebChat.isLocale("fr"))
        XCTAssertTrue(ZebChat.isLocale("pt-BR"))
        XCTAssertTrue(ZebChat.isLocale("zh_Hant"))
        XCTAssertFalse(ZebChat.isLocale(""))
        XCTAssertFalse(ZebChat.isLocale("fr&site=x"))
        XCTAssertFalse(ZebChat.isLocale("f"))
    }

    func testScreenURLsMatchAppScreenUrl() {
        XCTAssertEqual(AppScreen.url(appId: "com.example.app", screen: "  Checkout  "), "app://com.example.app/Checkout")
        XCTAssertEqual(
            AppScreen.url(appId: "com.example.app", screen: "Shop/Item Details?id=1"),
            "app://com.example.app/Shop/Item%20Details%3Fid%3D1"
        )
        XCTAssertEqual(AppScreen.url(appId: "com.example.app", screen: "Café (new)!"), "app://com.example.app/Caf%C3%A9%20(new)!")
    }
}
