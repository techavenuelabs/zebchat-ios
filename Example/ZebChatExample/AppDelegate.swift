import UIKit
import ZebChat

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        ZebChat.configure(siteKey: infoString("ZebChatSiteKey") ?? "zc_demo", options: Self.options())

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: DemoViewController())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// Point the example at a local stack with the ZEBCHAT_API_BASE_URL / ZEBCHAT_CHAT_PAGE_URL
    /// build settings (e.g. http://localhost:3000/api/v1 and http://localhost:5173/mobile.html).
    private static func options() -> ZebChatOptions {
        var options = ZebChatOptions()
        if let api = infoString("ZebChatAPIBaseURL").flatMap(URL.init(string:)) {
            options.apiBaseURL = api
        }
        if let page = infoString("ZebChatChatPageURL").flatMap(URL.init(string:)) {
            options.chatPageURL = page
        }
        return options
    }

    // Push wiring with Firebase Messaging (not linked in this example, see README.md):
    //   Messaging.messaging().apnsToken = deviceToken
    //   func messaging(_ messaging: Messaging, didReceiveRegistrationToken token: String?) {
    //       if let token { ZebChat.setPushToken(token) }
    //   }
}

private func infoString(_ key: String) -> String? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
    return value
}
