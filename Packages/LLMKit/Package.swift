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
        .library(name: "OpenAICompatibleTransport", targets: ["OpenAICompatibleTransport"]),
        .library(name: "BochaSearchAdapter", targets: ["BochaSearchAdapter"]),
        .library(name: "LLMKit", targets: ["LLMKit"])
    ],
    targets: [
        .target(name: "LLMCore"),
        .target(name: "AgentCore", dependencies: ["LLMCore"]),
        .target(name: "OpenAICompatibleTransport", dependencies: ["LLMCore"]),
        .target(name: "BochaSearchAdapter", dependencies: ["LLMCore"]),
        .target(
            name: "LLMKit",
            dependencies: [
                "LLMCore",
                "AgentCore",
                "OpenAICompatibleTransport",
                "BochaSearchAdapter"
            ]
        ),
        .testTarget(name: "LLMCoreTests", dependencies: ["LLMCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["LLMCore", "AgentCore"]),
        .testTarget(
            name: "OpenAICompatibleTransportTests",
            dependencies: ["LLMCore", "OpenAICompatibleTransport"]
        ),
        .testTarget(
            name: "BochaSearchAdapterTests",
            dependencies: ["LLMCore", "BochaSearchAdapter"]
        ),
        .testTarget(
            name: "LLMKitTests",
            dependencies: [
                "LLMCore",
                "AgentCore",
                "OpenAICompatibleTransport",
                "BochaSearchAdapter",
                "LLMKit"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
