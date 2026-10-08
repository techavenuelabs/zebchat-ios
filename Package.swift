// swift-tools-version:5.9
// ZebChat iOS SDK. This directory is mirrored to the public `zebchat-ios` repository for
// Swift Package Manager releases (see PUBLISHING.md).
import PackageDescription

let package = Package(
    name: "ZebChat",
    defaultLocalization: "en",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "ZebChat", targets: ["ZebChat"]),
    ],
    targets: [
        .target(
            name: "ZebChat",
            path: "Sources/ZebChat",
            resources: [
                .process("Resources"),
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "ZebChatTests",
            dependencies: ["ZebChat"],
            path: "Tests/ZebChatTests"
        ),
    ]
)
