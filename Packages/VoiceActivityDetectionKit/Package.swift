// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceActivityDetectionKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VoiceActivityDetectionKit",
            targets: ["VoiceActivityDetectionKit"]
        ),
        .library(
            name: "WebRTCVoiceActivityDetection",
            targets: ["WebRTCVoiceActivityDetection"]
        ),
        .executable(
            name: "VADBenchmark",
            targets: ["VADBenchmark"]
        )
    ],
    targets: [
        .target(name: "VoiceActivityDetectionKit"),
        .target(
            name: "CWebRTCVAD",
            path: "Sources/CWebRTCVAD",
            exclude: [
                "common_audio/signal_processing/division_operations.c",
                "common_audio/signal_processing/energy.c",
                "common_audio/signal_processing/get_scaling_square.c",
                "common_audio/signal_processing/resample_48khz.c",
                "common_audio/signal_processing/resample_by_2_internal.c",
                "common_audio/signal_processing/resample_fractional.c",
                "common_audio/vad/vad_core.c",
                "common_audio/vad/vad_filterbank.c",
                "common_audio/vad/vad_gmm.c",
                "common_audio/vad/vad_sp.c",
                "common_audio/vad/webrtc_vad.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),
        .target(
            name: "WebRTCVoiceActivityDetection",
            dependencies: ["VoiceActivityDetectionKit", "CWebRTCVAD"]
        ),
        .target(
            name: "CWebRTCVADTestSupport",
            dependencies: ["CWebRTCVAD"],
            path: "Tests/CWebRTCVADTestSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VADBenchmarkSupport",
            dependencies: ["VoiceActivityDetectionKit"]
        ),
        .executableTarget(
            name: "VADBenchmark",
            dependencies: ["VoiceActivityDetectionKit", "VADBenchmarkSupport"]
        ),
        .testTarget(
            name: "VoiceActivityDetectionKitTests",
            dependencies: ["VoiceActivityDetectionKit", "VADBenchmarkSupport"]
        ),
        .testTarget(
            name: "WebRTCVoiceActivityDetectionTests",
            dependencies: [
                "WebRTCVoiceActivityDetection",
                "CWebRTCVAD",
                "CWebRTCVADTestSupport"
            ]
        )
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
