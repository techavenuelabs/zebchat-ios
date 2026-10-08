import UIKit

/// ZebChat for iOS apps (docs/MOBILE_SDK.md §5).
///
/// ```swift
/// ZebChat.configure(siteKey: "zc_…")
/// ZebChat.setUser(ZebChatUser(id: "42", email: "a@b.com", name: "Ana", hash: serverHmac))
/// ZebChat.show(from: viewController)
/// ```
///
/// Every call is safe before `configure` (it logs and does nothing) and from any thread; the two
/// that present UI (`show`, `handleNotificationTap`) do so on the main thread.
/// Unread listeners are called on the main thread.
public enum ZebChat {
    public static let version = "1.0.0"

    private static let current = Locked<ZebChatClient?>(nil)
    private static let observingForeground = Locked(false)

    static var client: ZebChatClient? { current.get() }

    // MARK: - Setup

    /// Call once at launch (e.g. in `application(_:didFinishLaunchingWithOptions:)`).
    public static func configure(siteKey: String, options: ZebChatOptions = ZebChatOptions()) {
        guard NotificationPayload.isSiteKey(siteKey) else {
            Log.error("ZebChat.configure: \"\(siteKey)\" is not a site key (zc_…); ignored.")
            return
        }
        guard isLocale(options.locale) else {
            Log.error("ZebChat.configure: invalid locale \"\(options.locale)\"; ignored.")
            return
        }
        guard let app = AppInfo.current(wrapperSDK: options.wrapperSDK) else {
            Log.error("ZebChat.configure: the app has no bundle identifier; ignored.")
            return
        }
        if let existing = current.get(), existing.siteKey == siteKey,
           existing.options.apiBaseURL == options.apiBaseURL,
           existing.options.chatPageURL == options.chatPageURL,
           existing.options.wrapperSDK == options.wrapperSDK {
            existing.locale = options.locale
            existing.refresh()
            return
        }
        let client = ZebChatClient(
            siteKey: siteKey,
            options: options,
            app: app,
            store: KeychainStore(service: "com.zebchat.sdk.\(siteKey)")
        )
        current.set(client)
        observeForeground()
        client.refresh()
    }

    /// Chat language for the next `show(from:)`: `"auto"` (device language) or a code such as `"fr"`.
    public static func setLocale(_ locale: String) {
        guard let client = configuredClient("setLocale") else { return }
        guard isLocale(locale) else {
            Log.error("ZebChat.setLocale: invalid locale \"\(locale)\"; ignored.")
            return
        }
        client.locale = locale
    }

    // MARK: - User

    /// Identifies your signed-in user. Pass `hash` (computed on your server) with an `id`.
    /// If the chat is open, it restarts with the identified visitor.
    public static func setUser(_ user: ZebChatUser) {
        guard let client = configuredClient("setUser") else { return }
        client.setUser(user)
    }

    /// Signs the user out of the chat: deletes this device's push registration, then forgets the
    /// user and the visitor. The next chat starts as a new anonymous visitor.
    public static func logout() {
        guard let client = configuredClient("logout") else { return }
        client.logout()
    }

    // MARK: - Chat screen

    /// Presents the full-screen chat (on the main thread; callable from any thread).
    public static func show(from presenter: UIViewController) {
        guard let client = configuredClient("show") else { return }
        onMain { ChatPresenter.shared.show(client: client, from: presenter) }
    }

    /// `true` while the chat screen is on screen (e.g. to skip a foreground banner for ZebChat pushes).
    public static var isChatVisible: Bool {
        client?.isChatOpen ?? false
    }

    // MARK: - Tracking

    /// Records a screen view; agents see it live in the visitor list. Buffered (up to 20) while offline.
    public static func trackScreen(_ name: String) {
        guard let client = configuredClient("trackScreen") else { return }
        client.trackScreen(name)
    }

    /// Records a custom event (`name`: 1–64 of `A-Z a-z 0-9 _ . : -`), like `ZebChat.track()` on the web.
    public static func track(_ name: String, properties: [String: String]? = nil) {
        guard let client = configuredClient("track") else { return }
        guard name.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil else {
            Log.error("ZebChat.track: invalid event name; ignored.")
            return
        }
        client.track(event: name, properties: properties)
    }

    // MARK: - Push

    /// The FCM registration token from `Messaging.messaging().token` / `messaging(_:didReceiveRegistrationToken:)`.
    public static func setPushToken(_ token: String) {
        guard let client = configuredClient("setPushToken") else { return }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 4096 else {
            Log.error("ZebChat.setPushToken: invalid token; ignored.")
            return
        }
        client.setPushToken(trimmed)
    }

    /// `true` for a ZebChat push (`userInfo` of the notification, or FCM `data`).
    public static func isZebChatNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        NotificationPayload(userInfo: userInfo, expectedSiteKey: client?.siteKey) != nil
    }

    /// Call when a push arrives (e.g. in `userNotificationCenter(_:willPresent:withCompletionHandler:)`).
    /// Refreshes the unread count for a ZebChat push and returns whether it was one.
    @discardableResult
    public static func notificationReceived(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard isZebChatNotification(userInfo) else { return false }
        client?.refresh()
        return true
    }

    /// Opens the chat for a tapped ZebChat push. Returns `false` (and does nothing) for other pushes.
    /// Callable from any thread; the chat is presented on the main thread.
    @discardableResult
    public static func handleNotificationTap(_ userInfo: [AnyHashable: Any], from presenter: UIViewController) -> Bool {
        guard isZebChatNotification(userInfo) else { return false }
        guard let client = configuredClient("handleNotificationTap") else { return false }
        client.refresh()
        onMain { ChatPresenter.shared.show(client: client, from: presenter) }
        return true
    }

    // MARK: - Unread count

    /// The visitor's unread message count (as of the last refresh).
    public static var unreadCount: Int {
        UnreadCenter.shared.count
    }

    /// Calls `listener` on the main thread now and whenever the unread count changes.
    @discardableResult
    public static func addUnreadListener(_ listener: @escaping (Int) -> Void) -> ZebChatListenerToken {
        UnreadCenter.shared.add(listener)
    }

    public static func removeUnreadListener(_ token: ZebChatListenerToken) {
        UnreadCenter.shared.remove(token)
    }

    // MARK: - Internals

    private static func configuredClient(_ call: String) -> ZebChatClient? {
        guard let client = Self.client else {
            Log.error("ZebChat.\(call) was called before ZebChat.configure(siteKey:); ignored.")
            return nil
        }
        return client
    }

    /// Runs `body` on the main actor: right away on the main thread, otherwise on the next main
    /// run-loop turn. Lets the UI calls be made from any thread (Flutter / React Native wrappers).
    private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(body)
            }
        }
    }

    static func isLocale(_ value: String) -> Bool {
        value == "auto" || value.range(of: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }

    /// Refresh the unread count and send buffered screen views when the app returns to the foreground.
    private static func observeForeground() {
        observingForeground.update { observing in
            guard !observing else { return }
            observing = true
            _ = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: nil
            ) { _ in
                ZebChat.client?.refresh()
            }
        }
    }
}
