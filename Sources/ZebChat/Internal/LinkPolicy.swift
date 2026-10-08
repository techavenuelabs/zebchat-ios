import Foundation

/// Navigation policy of the chat web view (docs/MOBILE_SDK.md §2): only the chat page's origin
/// loads in the main frame; signed `/api/v1/files/:token` links are downloaded; other links open
/// in the system (browser, Mail, Phone); everything else is blocked.
enum LinkPolicy: Equatable {
    case allow
    case download
    case openExternally
    case block

    enum Target {
        case mainFrame
        case subframe
        /// `target=_blank` / `window.open` (no target frame).
        case newWindow
    }

    static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    static func decide(url: URL, target: Target, pageURL: URL, apiBaseURL: URL) -> LinkPolicy {
        guard let scheme = url.scheme?.lowercased() else { return .block }

        switch target {
        case .subframe:
            // Embedded frames (Cloudflare Turnstile): secure origins and their blank documents only.
            if ["about", "data", "blob"].contains(scheme) { return .allow }
            if scheme == "https" { return .allow }
            if scheme == "http", pageURL.scheme?.lowercased() == "http" { return .allow }
            return .block
        case .mainFrame:
            if scheme == "about", url.absoluteString == "about:blank" { return .allow }
            if isSameOrigin(url, pageURL) { return .allow }
            return route(url, scheme: scheme, apiBaseURL: apiBaseURL)
        case .newWindow:
            return route(url, scheme: scheme, apiBaseURL: apiBaseURL)
        }
    }

    private static func route(_ url: URL, scheme: String, apiBaseURL: URL) -> LinkPolicy {
        if isFileLink(url, apiBaseURL: apiBaseURL) { return .download }
        return externalSchemes.contains(scheme) ? .openExternally : .block
    }

    /// A signed attachment link: `<apiBaseURL>/files/<token>` on the API origin.
    static func isFileLink(_ url: URL, apiBaseURL: URL) -> Bool {
        guard isSameOrigin(url, apiBaseURL) else { return false }
        var basePath = apiBaseURL.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let prefix = basePath + "/files/"
        return url.path.hasPrefix(prefix) && url.path.count > prefix.count
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(), let rightScheme = rhs.scheme?.lowercased(),
              let leftHost = lhs.host?.lowercased(), let rightHost = rhs.host?.lowercased()
        else { return false }
        return leftScheme == rightScheme && leftHost == rightHost
            && effectivePort(lhs, leftScheme) == effectivePort(rhs, rightScheme)
    }

    private static func effectivePort(_ url: URL, _ scheme: String) -> Int {
        url.port ?? MobileBridge.defaultPort(for: scheme)
    }
}
