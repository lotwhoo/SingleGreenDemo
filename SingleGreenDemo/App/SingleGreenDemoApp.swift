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
        let settings = AISettings()
        _aiSettings = StateObject(wrappedValue: settings)
        let controller = VoiceConversationController(settings: settings)
        _conversationController = StateObject(wrappedValue: controller)
        _runtime = StateObject(wrappedValue: ExperienceRuntime(sessions: [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience(),
            AIConversationExperience(controller: controller)
        ]))
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(cameraController)
                .environmentObject(runtime)
                .environmentObject(profileStore)
                .environmentObject(aiSettings)
                .environmentObject(conversationController)
                .task(priority: .userInitiated) {
                    await cameraController.prepare()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            cameraController.handle(scenePhase: phase)
        }
    }
}
