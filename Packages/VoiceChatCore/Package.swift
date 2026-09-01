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
        .package(path: "../LLMKit"),
        .package(path: "../VoiceActivityDetectionKit")
    ],
    targets: [
        .target(
            name: "ASRDomain",
            dependencies: ["VoiceActivityDetectionKit"]
        ),
        .target(
            name: "ASRSupervision",
            dependencies: ["ASRDomain"]
        ),
        .target(
            name: "AudioCaptureApple",
            dependencies: ["ASRDomain", "VoiceActivityDetectionKit"]
        ),
        .target(
            name: "VoiceChatCore",
            dependencies: [
                "ASRDomain",
                "ASRSupervision",
                "AudioCaptureApple",
                "VoiceActivityDetectionKit"
            ]
        ),
        .testTarget(
            name: "AudioCaptureAppleTests",
            dependencies: ["ASRDomain", "AudioCaptureApple", "VoiceActivityDetectionKit"]
        ),
        .testTarget(
            name: "ASRDomainTests",
            dependencies: ["ASRDomain", "VoiceActivityDetectionKit"]
        ),
        .testTarget(
            name: "ASRSupervisionTests",
            dependencies: ["ASRDomain", "ASRSupervision"]
        ),
        .testTarget(
            name: "VoiceChatCoreTests",
            dependencies: [
                "ASRDomain",
                "ASRSupervision",
                "AudioCaptureApple",
                "VoiceChatCore",
                "VoiceActivityDetectionKit"
            ]
        ),
        .executableTarget(
            name: "ASRCLI",
            dependencies: ["VoiceChatCore", "LLMKit"],
            path: "Tools/ASRCLI"
        )
    ],
    swiftLanguageModes: [.v6]
)
