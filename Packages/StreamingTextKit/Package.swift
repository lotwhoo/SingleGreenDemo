// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamingTextKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "StreamingTextKit", targets: ["StreamingTextKit"])
    ],
    targets: [
        .target(name: "StreamingTextKit"),
        .testTarget(name: "StreamingTextKitTests", dependencies: ["StreamingTextKit"])
    ],
    swiftLanguageModes: [.v6]
)
