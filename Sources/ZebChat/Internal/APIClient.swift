import Foundation

enum APIError: Error, Equatable, Sendable {
    /// No HTTP response: offline, timeout, TLS failure.
    case network
    case http(status: Int)
    case invalidResponse

    /// Worth trying again later (screen views stay buffered).
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .http(let status): return status == 429 || status >= 500
        case .invalidResponse: return false
        }
    }
}

/// The widget endpoints the SDK calls, over URLSession (docs/MOBILE_SDK.md §5).
final class APIClient: @unchecked Sendable {
    private let baseURL: String
    private let session: URLSession
    private let app: AppInfo

    init(baseURL: URL, app: AppInfo, session: URLSession) {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        self.baseURL = base
        self.app = app
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: - Endpoints

    private struct SessionBody: Encodable {
        let siteKey: String
        let app: String
        let platform = "ios"
        let visitorKey: String?
    }

    /// `POST /widget/sessions` with `app` + `platform` (instead of a web `host`).
    func createSession(siteKey: String, visitorKey: String?) async throws -> WidgetSessionResponse {
        let body = SessionBody(siteKey: siteKey, app: app.appId, visitorKey: visitorKey)
        return try await decodeSession(send("POST", "widget/sessions", token: nil, body: body))
    }

    /// The `POST /widget/identify` body (`ApiClient.identityBody` on Android): only the fields that
    /// were set. An id without its hash (or the reverse) is dropped, since the API refuses it;
    /// name, email and phone are trimmed and left out when empty.
    struct IdentityBody: Encodable, Equatable {
        let id: String?
        let hash: String?
        let name: String?
        let email: String?
        let phone: String?

        init(_ user: ZebChatUser) {
            let id = user.id.flatMap { $0.isEmpty ? nil : $0 }
            let hash = user.hash.flatMap { $0.isEmpty ? nil : $0 }
            if let id, let hash {
                self.id = id
                self.hash = hash
            } else {
                if id != nil || hash != nil {
                    Log.error("ZebChatUser.id needs its hash (and the reverse): sending the profile without the id")
                }
                self.id = nil
                self.hash = nil
            }
            name = IdentityBody.cleaned(user.name)
            email = IdentityBody.cleaned(user.email)
            phone = IdentityBody.cleaned(user.phone)
        }

        private static func cleaned(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        // Synthesized encoding writes nil optionals with encodeIfPresent (left out), but spelled
        // out so the "only what was set" rule does not depend on it.
        private enum CodingKeys: String, CodingKey { case id, hash, name, email, phone }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encodeIfPresent(hash, forKey: .hash)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(email, forKey: .email)
            try container.encodeIfPresent(phone, forKey: .phone)
        }
    }

    /// `POST /widget/identify`: may return a session for a *different* visitor (adopt it).
    func identify(token: String, user: ZebChatUser) async throws -> WidgetSessionResponse {
        try await decodeSession(send("POST", "widget/identify", token: token, body: IdentityBody(user)))
    }

    private struct PageviewBody: Encodable {
        let url: String
        let title: String
        let client: MobileClientInfo
    }

    func pageview(token: String, url: String, title: String) async throws {
        _ = try await send("POST", "widget/pageviews", token: token, body: PageviewBody(url: url, title: title, client: app.client))
    }

    private struct EventBody: Encodable {
        let name: String
        let properties: [String: String]?
        let client: MobileClientInfo
    }

    func event(token: String, name: String, properties: [String: String]?) async throws {
        let body = EventBody(name: name, properties: properties, client: app.client)
        _ = try await send("POST", "widget/events", token: token, body: body)
    }

    private struct DeviceBody: Encodable {
        let token: String
        let platform = "ios"
        /// The bundle id: the API checks it against the website's allowed iOS apps.
        let appId: String
    }

    private struct DeviceDeleteBody: Encodable {
        let token: String
    }

    /// `POST /widget/devices`: registers (or moves) the push token to this visitor.
    func registerDevice(token: String, pushToken: String) async throws {
        _ = try await send("POST", "widget/devices", token: token, body: DeviceBody(token: pushToken, appId: app.appId))
    }

    /// `DELETE /widget/devices`.
    func deleteDevice(token: String, pushToken: String) async throws {
        _ = try await send("DELETE", "widget/devices", token: token, body: DeviceDeleteBody(token: pushToken))
    }

    private struct NoBody: Encodable {}

    private struct CurrentConversation: Decodable {
        let visitorUnreadCount: Int
    }

    /// `GET /widget/conversations/current` → the visitor's unread count (0 without a conversation).
    func unreadCount(token: String) async throws -> Int {
        let data = try await send("GET", "widget/conversations/current", token: token, body: NoBody?.none)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" { return 0 }
        guard let conversation = try? JSONDecoder().decode(CurrentConversation.self, from: data) else {
            throw APIError.invalidResponse
        }
        return max(0, conversation.visitorUnreadCount)
    }

    // MARK: - Transport

    private func decodeSession(_ data: Data) throws -> WidgetSessionResponse {
        guard let response = try? JSONDecoder().decode(WidgetSessionResponse.self, from: data), response.isValid else {
            throw APIError.invalidResponse
        }
        return response
    }

    private func send<Body: Encodable>(_ method: String, _ path: String, token: String?, body: Body?) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/\(path)") else { throw APIError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            guard let encoded = try? JSONEncoder().encode(body) else { throw APIError.invalidResponse }
            request.httpBody = encoded
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw APIError.http(status: response.statusCode)
        }
        return data
    }

    /// `URLSession.data(for:)` is iOS 15+; this wraps the completion-handler API for iOS 14.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if error != nil {
                    continuation.resume(throwing: APIError.network)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: APIError.invalidResponse)
                }
            }
            task.resume()
        }
    }
}
