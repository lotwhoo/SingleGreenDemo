// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SingleGreenGlassesKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SingleGreenGlassesKit", targets: ["SingleGreenGlassesKit"]),
        .executable(name: "TeleprompterBenchmark", targets: ["TeleprompterBenchmark"])
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
        .target(
            name: "TeleprompterEvaluationSupport",
            dependencies: ["SingleGreenGlassesKit"]
        ),
        .executableTarget(
            name: "TeleprompterBenchmark",
            dependencies: ["TeleprompterEvaluationSupport"]
        ),
        .testTarget(
            name: "SingleGreenGlassesKitTests",
            dependencies: [
                "SingleGreenGlassesKit",
                "TeleprompterEvaluationSupport",
                "VoiceChatDomain",
                "StreamingTextKit"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
