// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LLMKit", targets: ["LLMKit"])
    ],
    targets: [
        .target(name: "LLMKit"),
        .testTarget(name: "LLMKitTests", dependencies: ["LLMKit"])
    ]
)
