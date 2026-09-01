// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SingleGreenConversationAdapters",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SingleGreenConversationAdapters",
            targets: ["SingleGreenConversationAdapters"]
        )
    ],
    dependencies: [
        .package(path: "../SingleGreenGlassesKit"),
        .package(path: "../VoiceChatCore"),
        .package(path: "../LLMKit")
    ],
    targets: [
        .target(
            name: "SingleGreenConversationAdapters",
            dependencies: [
                "SingleGreenGlassesKit",
                "VoiceChatCore",
                .product(name: "AgentCore", package: "LLMKit"),
                .product(name: "LLMCore", package: "LLMKit")
            ]
        ),
        .testTarget(
            name: "SingleGreenConversationAdaptersTests",
            dependencies: [
                "SingleGreenConversationAdapters",
                "SingleGreenGlassesKit",
                "VoiceChatCore",
                .product(name: "AgentCore", package: "LLMKit"),
                .product(name: "LLMCore", package: "LLMKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
