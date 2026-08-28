// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceChatDomain",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "VoiceChatDomain", targets: ["VoiceChatDomain"])
    ],
    targets: [
        .target(name: "VoiceChatDomain"),
        .testTarget(name: "VoiceChatDomainTests", dependencies: ["VoiceChatDomain"])
    ],
    swiftLanguageModes: [.v6]
)
