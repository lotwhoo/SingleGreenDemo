// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LLMCore", targets: ["LLMCore"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "LLMKit", targets: ["LLMKit"])
    ],
    targets: [
        .target(name: "LLMCore"),
        .target(name: "AgentCore", dependencies: ["LLMCore"]),
        .target(name: "LLMKit", dependencies: ["LLMCore", "AgentCore"]),
        .testTarget(name: "LLMCoreTests", dependencies: ["LLMCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["LLMCore", "AgentCore"]),
        .testTarget(
            name: "LLMKitTests",
            dependencies: ["LLMCore", "AgentCore", "LLMKit"]
        )
    ],
    swiftLanguageModes: [.v6]
)
