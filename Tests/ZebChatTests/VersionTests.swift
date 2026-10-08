import XCTest
@testable import ZebChat

final class VersionTests: XCTestCase {
    /// `ZebChat.version` (sent as `sdk=ios/<version>`) and the podspec are released together.
    func testPodspecVersionMatchesTheSDKVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZebChatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // sdks/ios
        let podspec = try String(contentsOf: root.appendingPathComponent("ZebChat.podspec"), encoding: .utf8)
        let escaped = NSRegularExpression.escapedPattern(for: ZebChat.version)
        XCTAssertNotNil(
            podspec.range(of: #"s\.version\s*=\s*'"# + escaped + "'", options: .regularExpression),
            "bump ZebChat.podspec and ZebChat.version together"
        )
    }

    func testDefaultSDKIdentifier() {
        let info = AppInfo.current(wrapperSDK: nil, bundle: Bundle(for: VersionTests.self))
        // The test bundle has an identifier on the simulator; when it does, the SDK string is ios/<version>.
        if let info {
            XCTAssertEqual(info.sdk, "ios/\(ZebChat.version)")
            XCTAssertEqual(info.client.sdk, "ios/\(ZebChat.version)")
            XCTAssertEqual(info.client.platform, "ios")
        }
        let wrapped = AppInfo.current(wrapperSDK: "flutter/1.0.0", bundle: Bundle(for: VersionTests.self))
        if let wrapped {
            XCTAssertEqual(wrapped.sdk, "flutter/1.0.0")
            XCTAssertEqual(wrapped.client.sdk, "flutter/1.0.0")
        }
    }

    func testMachineIdentifierIsNotEmpty() {
        XCTAssertFalse(AppInfo.machineIdentifier().isEmpty)
    }
}
