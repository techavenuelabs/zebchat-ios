import XCTest
@testable import ZebChat

final class LinkPolicyTests: XCTestCase {
    private let page = URL(string: "https://cdn.zebchat.com/widget/v1/mobile.html?site=zc_demo")!
    private let api = URL(string: "https://api.zebchat.com/api/v1")!

    private func decide(_ link: String, _ target: LinkPolicy.Target) -> LinkPolicy {
        LinkPolicy.decide(url: URL(string: link)!, target: target, pageURL: page, apiBaseURL: api)
    }

    func testMainFrameLoadsOnlyTheChatPageOrigin() {
        XCTAssertEqual(decide("https://cdn.zebchat.com/widget/v1/mobile.html?site=zc_demo&locale=fr", .mainFrame), .allow)
        XCTAssertEqual(decide("about:blank", .mainFrame), .allow)
        XCTAssertEqual(decide("https://example.com/pricing", .mainFrame), .openExternally)
        XCTAssertEqual(decide("http://cdn.zebchat.com/widget/v1/mobile.html", .mainFrame), .openExternally)
        XCTAssertEqual(decide("javascript:alert(1)", .mainFrame), .block)
        XCTAssertEqual(decide("file:///etc/hosts", .mainFrame), .block)
        XCTAssertEqual(decide("data:text/html,hi", .mainFrame), .block)
        XCTAssertEqual(decide("otherapp://open", .mainFrame), .block)
    }

    func testSignedFileLinksAreDownloaded() {
        XCTAssertEqual(decide("https://api.zebchat.com/api/v1/files/tok_123", .mainFrame), .download)
        XCTAssertEqual(decide("https://api.zebchat.com/api/v1/files/tok_123", .newWindow), .download)
        XCTAssertEqual(decide("https://api.zebchat.com/api/v1/filesx/tok", .newWindow), .openExternally)
        XCTAssertEqual(decide("https://evil.example/api/v1/files/tok", .newWindow), .openExternally)
        XCTAssertFalse(LinkPolicy.isFileLink(URL(string: "https://api.zebchat.com/api/v1/files/")!, apiBaseURL: api))
    }

    func testNewWindowsOpenOutsideTheApp() {
        XCTAssertEqual(decide("https://www.zebchat.com/", .newWindow), .openExternally)
        XCTAssertEqual(decide("mailto:help@example.com", .newWindow), .openExternally)
        XCTAssertEqual(decide("tel:+15551234", .newWindow), .openExternally)
        XCTAssertEqual(decide("sms:+15551234", .newWindow), .block)
    }

    func testSubframesAllowSecureEmbedsOnly() {
        XCTAssertEqual(decide("https://challenges.cloudflare.com/turnstile/v0/", .subframe), .allow)
        XCTAssertEqual(decide("about:blank", .subframe), .allow)
        XCTAssertEqual(decide("http://insecure.example/", .subframe), .block)
        XCTAssertEqual(decide("otherapp://x", .subframe), .block)
    }

    func testDownloadNamesAreSanitized() {
        XCTAssertEqual(DownloadFiles.sanitize("report.pdf"), "report.pdf")
        XCTAssertEqual(DownloadFiles.sanitize("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(DownloadFiles.sanitize("a:b?c.txt"), "a_b_c.txt")
        XCTAssertEqual(DownloadFiles.sanitize("   "), "download")
        XCTAssertEqual(DownloadFiles.sanitize(".."), "download")
        let long = String(repeating: "x", count: 300) + ".png"
        let sanitized = DownloadFiles.sanitize(long)
        XCTAssertEqual(sanitized.count, DownloadFiles.nameMax)
        XCTAssertTrue(sanitized.hasSuffix(".png"))
    }

    func testDownloadDestinationIsFreshAndInsideTheTemporaryDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try XCTUnwrap(DownloadFiles.destination(for: "photo.jpg", in: base))
        let second = try XCTUnwrap(DownloadFiles.destination(for: "photo.jpg", in: base))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "photo.jpg")
        XCTAssertTrue(first.path.hasPrefix(base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testDiscardDeletesTheDownloadAndItsDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try XCTUnwrap(DownloadFiles.destination(for: "photo.jpg", in: base))
        try Data("x".utf8).write(to: file)
        DownloadFiles.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))

        // Anything outside a per-download directory is left alone.
        let stray = base.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: stray)
        DownloadFiles.discard(stray)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }
}
