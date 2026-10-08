import Foundation

/// Bridge v1 between the native SDK and `mobile.html` (docs/MOBILE_SDK.md §2,
/// `packages/types/src/mobile.ts`).
enum MobileBridge {
    static let version = 1
    /// `webkit.messageHandlers.zebchat.postMessage('<json>')`.
    static let messageHandlerName = "zebchat"
    static let tokenMax = 4096
    static let errorMessageMax = 500
    /// Upper bound for a page message before it is parsed at all.
    static let messageBytesMax = 64 * 1024

    /// Accepts a script message only from the main frame of the chat page's origin (the Turnstile
    /// iframe shares the web view).
    static func isTrustedSender(
        isMainFrame: Bool,
        scheme: String,
        host: String,
        port: Int,
        pageURL: URL
    ) -> Bool {
        guard isMainFrame,
              let expectedScheme = pageURL.scheme?.lowercased(),
              let expectedHost = pageURL.host?.lowercased(),
              !host.isEmpty
        else { return false }
        guard scheme.lowercased() == expectedScheme, host.lowercased() == expectedHost else { return false }
        if let expectedPort = pageURL.port {
            return port == expectedPort
        }
        // WebKit reports 0 for the scheme's default port.
        return port == 0 || port == defaultPort(for: expectedScheme)
    }

    static func defaultPort(for scheme: String) -> Int {
        scheme == "http" ? 80 : 443
    }

    /// The script that hands a session to the page (`window.ZebChatBridge.receive('<json>')`).
    static func initScript(for session: StoredSession) -> String? {
        let message = MobileInitMessage(token: session.token, expiresAt: session.expiresAt, visitor: session.visitor)
        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(message),
              let jsonText = String(data: json, encoding: .utf8),
              // Encoding the JSON text again yields a safely escaped JavaScript string literal.
              let literal = try? encoder.encode(jsonText),
              let literalText = String(data: literal, encoding: .utf8)
        else { return nil }
        return "window.ZebChatBridge&&window.ZebChatBridge.receive(\(literalText));true"
    }

    /// The chat page URL with the query the page reads at load.
    static func pageURL(base: URL, siteKey: String, appId: String, sdk: String, locale: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter {
            !["site", "app", "platform", "sdk", "locale"].contains($0.name)
        }
        items.append(URLQueryItem(name: "site", value: siteKey))
        items.append(URLQueryItem(name: "app", value: appId))
        items.append(URLQueryItem(name: "platform", value: "ios"))
        items.append(URLQueryItem(name: "sdk", value: sdk))
        items.append(URLQueryItem(name: "locale", value: locale))
        components.queryItems = items
        return components.url
    }
}

/// Native → page `init` (`MobileInitMessage`): same shape as the pop-out session handoff.
struct MobileInitMessage: Encodable {
    let type = "init"
    let v = MobileBridge.version
    let token: String
    let expiresAt: String
    let visitor: ZebChatVisitor
}

/// Page → native messages (`MobilePageMessage`). Unknown or malformed messages parse to `nil`.
enum MobilePageMessage: Equatable {
    case ready
    case renewed(token: String, expiresAt: String)
    case expired
    case close
    case error(status: Int, message: String)

    /// Parses a `WKScriptMessage.body`: the JSON string the page posts (or an already decoded object).
    static func parse(_ body: Any) -> MobilePageMessage? {
        let object: Any
        if let text = body as? String {
            guard text.utf8.count <= MobileBridge.messageBytesMax,
                  let data = text.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            object = decoded
        } else {
            object = body
        }
        guard let record = object as? [String: Any], let type = record["type"] as? String else { return nil }
        switch type {
        case "ready":
            return JSONValue.integer(record["v"]) == MobileBridge.version ? .ready : nil
        case "renewed":
            guard let token = JSONValue.text(record["token"], max: MobileBridge.tokenMax),
                  let expiresAt = JSONValue.isoDate(record["expiresAt"])
            else { return nil }
            return .renewed(token: token, expiresAt: expiresAt)
        case "expired":
            return .expired
        case "close":
            return .close
        case "error":
            guard let status = JSONValue.integer(record["status"]),
                  let message = record["message"] as? String,
                  message.utf16.count <= MobileBridge.errorMessageMax
            else { return nil }
            return .error(status: status, message: message)
        default:
            return nil
        }
    }
}
