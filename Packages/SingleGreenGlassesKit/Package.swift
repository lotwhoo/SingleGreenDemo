// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SingleGreenGlassesKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SingleGreenGlassesKit", targets: ["SingleGreenGlassesKit"])
    ],
    dependencies: [
        .package(path: "../VoiceChatDomain"),
        .package(path: "../StreamingTextKit")
    ],
    targets: [
        .target(
            name: "SingleGreenGlassesKit",
            dependencies: ["VoiceChatDomain", "StreamingTextKit"]
        ),
        .testTarget(
            name: "SingleGreenGlassesKitTests",
            dependencies: ["SingleGreenGlassesKit", "VoiceChatDomain", "StreamingTextKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
