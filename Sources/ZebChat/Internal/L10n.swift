import Foundation

/// The SDK's own strings (the error screen); the chat itself is translated by the page.
enum L10n {
    static let errorTitle = "chat.error.title"
    static let errorMessage = "chat.error.message"
    static let retry = "chat.error.retry"
    static let close = "chat.close"
    static let loading = "chat.loading"

    /// `locale`: `"auto"` (device language) or a code such as `"fr"` / `"pt-BR"`, as for the page.
    static func string(_ key: String, locale: String) -> String {
        let bundle = localizedBundle(for: locale)
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private static func localizedBundle(for locale: String) -> Bundle {
        let resources = ResourceBundle.bundle
        let preferences = locale == "auto" ? Locale.preferredLanguages : [locale]
        let match = Bundle.preferredLocalizations(from: resources.localizations, forPreferences: preferences).first
        if let match,
           let path = resources.path(forResource: match, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = resources.path(forResource: "en", ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        return resources
    }
}

/// The bundle holding the SDK resources (Swift Package Manager or CocoaPods resource bundle).
enum ResourceBundle {
    private final class Marker {}

    static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let candidates = [Bundle(for: Marker.self), Bundle.main]
        for candidate in candidates {
            if let url = candidate.url(forResource: "ZebChat", withExtension: "bundle"),
               let resources = Bundle(url: url) {
                return resources
            }
        }
        return Bundle(for: Marker.self)
        #endif
    }()
}
