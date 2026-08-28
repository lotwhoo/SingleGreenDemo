import SingleGreenGlassesKit
import SwiftUI

@main
struct SingleGreenDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraController = CameraSessionController()
    @StateObject private var runtime: ExperienceRuntime
    @StateObject private var profileStore = DisplayProfileStore()
    @StateObject private var aiSettings: AISettings
    @StateObject private var conversationController: VoiceConversationController

    init() {
        let settings = Self.makeAISettings()
        _aiSettings = StateObject(wrappedValue: settings)
        let controller = VoiceConversationController(dependencies: .live(settings: settings))
        _conversationController = StateObject(wrappedValue: controller)
        _runtime = StateObject(wrappedValue: Self.makeRuntime(controller: controller))
    }

    @MainActor
    static func makeAISettings() -> AISettings {
        // The production App target explicitly links the detector product;
        // isolated settings fixtures remain fail-closed unless they opt in.
        AISettings(speechInputAvailability: .productionDetectorAvailable)
    }

    @MainActor
    private static func makeRuntime(
        controller: VoiceConversationController
    ) -> ExperienceRuntime {
        do {
            return try ExperienceRuntime(
                validating: DemoExperienceComposition.sessions(controller: controller)
            )
        } catch {
            preconditionFailure("Invalid built-in experience composition: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(cameraController)
                .environmentObject(runtime)
                .environmentObject(profileStore)
                .environmentObject(aiSettings)
                .task(priority: .userInitiated) {
                    await cameraController.prepare()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            cameraController.handle(scenePhase: phase)
            switch phase {
            case .background:
                conversationController.updateHostLifecycle(.background)
            case .active:
                conversationController.updateHostLifecycle(.active)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

@MainActor
enum DemoExperienceComposition {
    static let aiProviderDetail = "豆包 ASR → DeepSeek Agent → 博查搜索"

    static func sessions(controller: VoiceConversationController) -> [any ExperienceSession] {
        [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience(),
            AIConversationExperience(
                controller: controller,
                providerDetail: aiProviderDetail
            )
        ]
    }
}
