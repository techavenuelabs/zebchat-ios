import Foundation

/// Where downloaded attachments go before the share sheet hands them to the user.
enum DownloadFiles {
    static let nameMax = 120

    /// A fresh, not yet existing file URL (WebKit refuses to overwrite) in the temporary directory.
    static func destination(
        for suggestedFilename: String,
        in base: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let directory = base
            .appendingPathComponent("ZebChatDownloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent(sanitize(suggestedFilename), isDirectory: false)
    }

    /// Deletes a `destination(for:)` file and its per-download directory (after the share sheet).
    static func discard(_ file: URL) {
        let directory = file.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().lastPathComponent == "ZebChatDownloads" else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A safe single path component; keeps the end of long names so the extension survives.
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let limited = String(cleaned.suffix(nameMax))
        return limited.isEmpty ? "download" : limited
    }
}
