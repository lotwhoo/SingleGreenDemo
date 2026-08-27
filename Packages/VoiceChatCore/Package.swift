// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceChatCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceChatCore", targets: ["VoiceChatCore"])
    ],
    dependencies: [
        .package(path: "../LLMKit")
    ],
    targets: [
        .target(name: "VoiceChatCore"),
        .testTarget(name: "VoiceChatCoreTests", dependencies: ["VoiceChatCore"]),
        .executableTarget(
            name: "ASRCLI",
            dependencies: ["VoiceChatCore", "LLMKit"],
            path: "Tools/ASRCLI"
        )
    ]
)
