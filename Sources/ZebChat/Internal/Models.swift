import Foundation

/// The visitor session the SDK caches and hands to the page as `init`.
struct StoredSession: Codable, Equatable, Sendable {
    var token: String
    /// ISO 8601.
    var expiresAt: String
    var visitor: ZebChatVisitor
    /// The user this session was identified for (`nil` = anonymous). A different current user
    /// means the session must be re-created.
    var user: ZebChatUser?

    /// Sessions are reused until shortly before the token expires.
    static let renewMargin: TimeInterval = 5 * 60

    func isFresh(at now: Date) -> Bool {
        guard let expiry = ISODate.parse(expiresAt) else { return false }
        return expiry.timeIntervalSince(now) > Self.renewMargin
    }
}

/// `WidgetSession` from `POST /widget/sessions` and `POST /widget/identify`.
struct WidgetSessionResponse: Decodable, Sendable {
    let visitorToken: String
    let visitorTokenExpiresAt: String
    /// Present only when a new visitor was created.
    let visitorKey: String?
    let visitor: ZebChatVisitor

    var isValid: Bool {
        !visitorToken.isEmpty && visitorToken.utf16.count <= MobileBridge.tokenMax
            && ISODate.parse(visitorTokenExpiresAt) != nil
            && !visitor.id.isEmpty && visitor.id.utf16.count <= 100
            && (visitorKey.map { !$0.isEmpty && $0.count <= 100 } ?? true)
    }
}

/// `MobileClientInfo`: sent with every screen view and event.
struct MobileClientInfo: Encodable, Equatable, Sendable {
    enum DeviceType: String, Encodable, Sendable {
        case phone, tablet
    }

    /// `MOBILE_CLIENT_LIMITS` in packages/types.
    enum Limits {
        static let appId = 155
        static let appVersion = 40
        static let sdk = 40
        static let osVersion = 40
        static let deviceModel = 80
    }

    let platform = "ios"
    let appId: String
    let appVersion: String?
    let sdk: String?
    let osVersion: String?
    let deviceModel: String?
    let deviceType: DeviceType?

    init(appId: String, appVersion: String?, sdk: String?, osVersion: String?, deviceModel: String?, deviceType: DeviceType?) {
        self.appId = String(appId.prefix(Limits.appId))
        self.appVersion = appVersion.map { String($0.prefix(Limits.appVersion)) }
        self.sdk = sdk.map { String($0.prefix(Limits.sdk)) }
        self.osVersion = osVersion.map { String($0.prefix(Limits.osVersion)) }
        self.deviceModel = deviceModel.map { String($0.prefix(Limits.deviceModel)) }
        self.deviceType = deviceType
    }
}

/// Facts about the host app and device.
struct AppInfo: Equatable, Sendable {
    /// The bundle id, checked by the API against the website's allowed iOS apps.
    let appId: String
    /// `ios/<version>` or the wrapper's `flutter/<version>` / `react-native/<version>`.
    let sdk: String
    let client: MobileClientInfo

    init(appId: String, sdk: String, client: MobileClientInfo) {
        self.appId = appId
        self.sdk = sdk
        self.client = client
    }

    static func current(wrapperSDK: String?, bundle: Bundle = .main) -> AppInfo? {
        guard let appId = bundle.bundleIdentifier, !appId.isEmpty else { return nil }
        let sdk = wrapperSDK ?? "ios/\(ZebChat.version)"
        let model = machineIdentifier()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
        let client = MobileClientInfo(
            appId: appId,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            sdk: sdk,
            osVersion: osVersion,
            deviceModel: model,
            deviceType: model.hasPrefix("iPad") ? .tablet : .phone
        )
        return AppInfo(appId: appId, sdk: sdk, client: client)
    }

    /// e.g. `iPhone15,2` (the simulator reports the simulated model).
    static func machineIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Screen views are page views with `url: app://<appId>/<screen-path>` (`appScreenUrl` in packages/types).
enum AppScreen {
    static let nameMax = 200
    static let titleMax = 300

    /// `encodeURIComponent` keeps these characters.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    static func url(appId: String, screen: String) -> String {
        let trimmed = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = (trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
            .replacingOccurrences(of: "%2F", with: "/")
        return "app://\(appId)/\(encoded)"
    }
}

/// The data of a ZebChat push (`VisitorPushData`: `{zebchat: '1', conversationId, siteKey}`).
struct NotificationPayload: Equatable {
    let conversationId: String
    let siteKey: String

    /// `^zc_[A-Za-z0-9_]{3,64}$`, as the API validates site keys.
    static func isSiteKey(_ value: String) -> Bool {
        value.range(of: "^zc_[A-Za-z0-9_]{3,64}$", options: .regularExpression) != nil
    }

    /// `nil` unless `userInfo` is a ZebChat push (for `expectedSiteKey`, when one is configured).
    init?(userInfo: [AnyHashable: Any], expectedSiteKey: String?) {
        let marker = userInfo["zebchat"]
        let isMarked = (marker as? String) == "1" || JSONValue.integer(marker) == 1
        guard isMarked,
              let siteKey = userInfo["siteKey"] as? String, Self.isSiteKey(siteKey),
              let conversationId = JSONValue.text(userInfo["conversationId"], max: 100)
        else { return nil }
        if let expectedSiteKey, expectedSiteKey != siteKey { return nil }
        self.conversationId = conversationId
        self.siteKey = siteKey
    }
}
