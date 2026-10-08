import Foundation

/// Settings for `ZebChat.configure(siteKey:options:)`.
public struct ZebChatOptions: Equatable, Sendable {
    /// Chat language: `"auto"` (the device language) or a language code such as `"fr"` or `"pt-BR"`.
    public var locale: String
    /// ZebChat API base, including `/api/v1`. Override only for a self-hosted or staging setup.
    public var apiBaseURL: URL
    /// The mobile chat page shown in the chat screen. Override only for a self-hosted or staging setup.
    public var chatPageURL: URL
    /// Set by the Flutter and React Native plugins (e.g. `"flutter/1.0.0"`); leave `nil` in apps.
    public var wrapperSDK: String?

    public static let defaultAPIBaseURL = URL(string: "https://api.zebchat.com/api/v1")!
    public static let defaultChatPageURL = URL(string: "https://cdn.zebchat.com/widget/v1/mobile.html")!

    public init(
        locale: String = "auto",
        apiBaseURL: URL = ZebChatOptions.defaultAPIBaseURL,
        chatPageURL: URL = ZebChatOptions.defaultChatPageURL,
        wrapperSDK: String? = nil
    ) {
        self.locale = locale
        self.apiBaseURL = apiBaseURL
        self.chatPageURL = chatPageURL
        self.wrapperSDK = wrapperSDK
    }
}

/// The signed-in user of your app, passed to `ZebChat.setUser(_:)`.
///
/// A user `id` needs `hash`: the hex HMAC-SHA256 of the id keyed with the website's identity
/// secret, computed on **your server** (never ship the secret in the app). Without an id, name,
/// email and phone are saved on the visitor as unverified details.
public struct ZebChatUser: Codable, Equatable, Sendable {
    public var id: String?
    public var email: String?
    public var name: String?
    public var phone: String?
    public var hash: String?

    public init(
        id: String? = nil,
        email: String? = nil,
        name: String? = nil,
        phone: String? = nil,
        hash: String? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.phone = phone
        self.hash = hash
    }
}

/// The ZebChat visitor of this device (mirrors `WidgetVisitor` in `packages/types`).
public struct ZebChatVisitor: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let email: String?
    public let phone: String?
    /// Identity proven with a valid `setUser` hash.
    public let verified: Bool

    public init(id: String, name: String?, email: String?, phone: String?, verified: Bool) {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
        self.verified = verified
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, email, phone, verified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
    }

    /// Writes explicit `null`s, like the API's `WidgetVisitor`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(phone, forKey: .phone)
        try container.encode(verified, forKey: .verified)
    }
}

/// Returned by `ZebChat.addUnreadListener(_:)`; pass it to `removeUnreadListener(_:)`.
public struct ZebChatListenerToken: Hashable, Sendable {
    let id: UUID
}
