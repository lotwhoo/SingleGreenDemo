// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SingleGreenCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SingleGreenCore", targets: ["SingleGreenCore"])
    ],
    targets: [
        .target(
            name: "SingleGreenCore",
            path: "SingleGreenDemo",
            exclude: [
                "App",
                "Assets.xcassets",
                "Experiences/AIConversation",
                "Platform/AI",
                "Platform/Environment",
                "Platform/Interaction",
                "Platform/Rendering"
            ],
            sources: [
                "Platform/Domain/DemoEvent.swift",
                "Platform/Domain/HUDScene.swift",
                "Platform/Domain/NormalizedGeometry.swift",
                "Platform/Profiles/DisplayProfile.swift",
                "Platform/Runtime/ExperienceSession.swift",
                "Platform/Runtime/ExperienceRuntime.swift",
                "Experiences/SystemStatus/SystemStatusExperience.swift",
                "Experiences/Navigation/NavigationExperience.swift",
                "Experiences/Notification/NotificationExperience.swift",
                "Experiences/Caption/CaptionExperience.swift"
            ]
        ),
        .testTarget(
            name: "SingleGreenCoreTests",
            dependencies: ["SingleGreenCore"],
            path: "SingleGreenCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
