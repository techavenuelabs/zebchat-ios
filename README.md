# ZebChat iOS SDK

Live chat with your customers inside your iOS app. The SDK shows the ZebChat chat full screen,
keeps the visitor (and their conversations) across launches, identifies your signed-in users,
sends screen views your agents see live, and delivers agent replies as push notifications
through **your own Firebase project**.

- iOS 14+, Swift 5.9+, UIKit and WebKit only. No third-party dependencies (not even Firebase:
  your app forwards the push token).
- Swift Package Manager or CocoaPods.

## 1. Allow your app

In the ZebChat dashboard: **Websites → (your website) → Mobile apps**, add your app's **bundle
identifier** under iOS. Sessions from apps that are not listed are refused (`403`).

## 2. Install

**Swift Package Manager** — Xcode → File → Add Package Dependencies…:

```
https://github.com/techavenuelabs/zebchat-ios
```

Version rule "Up to Next Major" from `1.0.0`; add the `ZebChat` library to your app target. Or
in `Package.swift`:

```swift
.package(url: "https://github.com/techavenuelabs/zebchat-ios", from: "1.0.0")
```

**CocoaPods**:

```ruby
pod 'ZebChat', '~> 1.0'
```

### Info.plist (required)

The chat lets visitors send photos and files. iOS shows the picker from the web view, so **your
app's** Info.plist must explain camera and photo access (the SDK cannot declare these for you;
without them iOS terminates the app when the picker opens):

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo to send in the chat.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Choose photos to send in the chat.</string>
```

## 3. Quick start

```swift
import ZebChat

// AppDelegate.application(_:didFinishLaunchingWithOptions:)
ZebChat.configure(siteKey: "zc_…")           // your website's site key

// Open the chat (full screen, modal)
ZebChat.show(from: viewController)
```

That is all you need for anonymous visitors. Everything else is optional:

```swift
// Your signed-in user. `hash` is HMAC-SHA256(user id, identity secret) computed on YOUR server
// (Website → Identity verification); never put the secret in the app.
ZebChat.setUser(ZebChatUser(id: "42", email: "ana@example.com", name: "Ana", hash: hashFromServer))

// Without an id (no hash needed) the details are saved as unverified:
ZebChat.setUser(ZebChatUser(email: "ana@example.com", name: "Ana"))

// Sign-out: removes this device's push registration, then forgets the user and the visitor.
ZebChat.logout()

// Screen views (agents see them live; up to 20 are kept while offline)
ZebChat.trackScreen("Checkout")

// Custom events, like ZebChat.track() on the web
ZebChat.track("checkout_started", properties: ["plan": "pro"])

// Unread messages (e.g. a badge on your help button). Called on the main thread, right away
// with the current count and then on every change.
let token = ZebChat.addUnreadListener { count in helpButton.badge = count }
ZebChat.removeUnreadListener(token)

// Chat language: "auto" (device language, the default) or a code; applies on the next show().
ZebChat.setLocale("fr")
```

`ZebChat.configure(siteKey:options:)` takes `ZebChatOptions(locale:)`. Every call is safe before
`configure` (it logs and does nothing) and from any thread. `show(from:)` and
`handleNotificationTap(_:from:)` present the chat on the main thread (right away when called on
it, otherwise on the next main run-loop turn).

**Session model.** The SDK stores a visitor key in the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced or migrated) and caches the
visitor session until shortly before it expires, so cold starts rarely call the API. `setUser`
may switch to the visitor that already belongs to that user (their history follows them across
devices); signing in as a different user id without `logout()` logs the previous one out first.
Keychain items survive an app reinstall, so a reinstalled app keeps its visitor until `logout()`.

## 4. Push notifications (Firebase Cloud Messaging)

ZebChat sends pushes for agent replies through **your** Firebase project; Firebase forwards
them to APNs. The SDK does not link Firebase; your app does.

1. **Firebase**: add your iOS app to your Firebase project and add `FirebaseMessaging`
   ([Firebase setup](https://firebase.google.com/docs/cloud-messaging/ios/client)).
2. **APNs key**: in the Apple Developer portal create an APNs authentication key (.p8) and upload
   it in Firebase → Project settings → Cloud Messaging → Apple app configuration.
3. **Xcode**: enable the _Push Notifications_ capability.
4. **ZebChat dashboard**: Website → Mobile apps → upload the Firebase **service account** JSON
   (Firebase → Project settings → Service accounts → Generate new private key) and use
   _Send test push_ with a device token.
5. **Code**: forward the APNs token to Firebase and the FCM token to ZebChat, and hand ZebChat
   its notifications:

```swift
import FirebaseCore
import FirebaseMessaging
import UserNotifications
import ZebChat

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        FirebaseApp.configure()
        ZebChat.configure(siteKey: "zc_…")
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        // Ask when it suits your app (the SDK never asks for permission itself).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }

    // APNs token → Firebase (needed when Firebase's method swizzling is disabled; harmless otherwise).
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    // FCM token → ZebChat (also called when the token rotates).
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let fcmToken { ZebChat.setPushToken(fcmToken) }
    }

    // A push while the app is open: refresh the unread count; no banner while the chat is visible.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if ZebChat.notificationReceived(userInfo) {
            completionHandler(ZebChat.isChatVisible ? [] : [.banner, .sound])
        } else {
            completionHandler([.banner, .sound, .badge])
        }
    }

    // A tapped push opens the chat (also after a cold start).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let root = window?.rootViewController {   // scene-based apps: the active scene's window
            ZebChat.handleNotificationTap(userInfo, from: root)
        }
        completionHandler()
    }
}
```

A ZebChat push carries the data `{zebchat: "1", conversationId, siteKey, title, body}` (no
visitor details); `ZebChat.isZebChatNotification(_:)` tells them apart from your own pushes. The
badge is the visitor's unread count. Pushes are skipped while the visitor is online (the chat is
open in the app, or the website is open in a browser tab).

## Links, files and privacy

- Only the ZebChat chat page loads inside the chat screen. Links open in Safari (or Mail /
  Phone); attachments are downloaded (iOS 14.5+) and offered in the share sheet (save to Files /
  Photos), or opened in Safari on iOS 14.0–14.4. The temporary copy is deleted when the share
  sheet closes.
- The visitor key never enters the web view or a URL; the page only receives a short-lived
  visitor token.
- The chat screen always has a way out: a native close button shows while the page loads, after
  the page reports an error, and with a Retry / Close screen when the page fails to load or does
  not start within 15 seconds.
- The SDK ships a `PrivacyInfo.xcprivacy`: no tracking; user ID, email, name, phone, customer
  support messages, photos and other user content, product interaction (`trackScreen` / `track`)
  and coarse location (the country the server derives from the IP address) are collected, linked
  to the user, for app functionality. Reflect this in your App Store privacy answers.

## Example app

`Example/` is a UIKit app that uses the package from this directory. Its Xcode project is
generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd sdks/ios/Example && xcodegen generate && open ZebChatExample.xcodeproj
```

Set your site key in the `ZEBCHAT_SITE_KEY` build setting (and add `com.zebchat.example` to the
website's iOS apps). For a local stack (`pnpm dev`) set `ZEBCHAT_API_BASE_URL` to
`http://localhost:3000/api/v1` and `ZEBCHAT_CHAT_PAGE_URL` to the widget dev server's
`mobile.html`.

## Development

```bash
cd sdks/ios
xcodebuild test -scheme ZebChat -destination 'platform=iOS Simulator,name=iPhone 16'
pod lib lint ZebChat.podspec --allow-warnings
```

CI runs both plus the example build on macOS (`.github/workflows/sdk-ios.yml`). Self-hosted or
staging setups can override `ZebChatOptions.apiBaseURL` and `chatPageURL`. The Flutter and
React Native plugins wrap this SDK and set `ZebChatOptions.wrapperSDK` (`flutter/<version>`,
`react-native/<version>`). Releases: see [PUBLISHING.md](PUBLISHING.md).
