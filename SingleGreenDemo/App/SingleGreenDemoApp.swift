import SingleGreenGlassesKit
import SwiftUI
import UIKit

@main
struct SingleGreenDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var cameraController = CameraSessionController()
    @StateObject private var runtime: ExperienceRuntime
    @StateObject private var profileStore = DisplayProfileStore()
    @StateObject private var aiSettings: AISettings
    @StateObject private var teleprompterSettings: TeleprompterSettings
    @StateObject private var conversationController: VoiceConversationController
    @StateObject private var textAdventureController: TextAdventureController
    @StateObject private var teleprompterController: TeleprompterController
    @StateObject private var diagnostics: ConversationTelemetryStore

    init() {
        let settings = Self.makeAISettings()
        _aiSettings = StateObject(wrappedValue: settings)
        let credentialProvider = AIServiceComposition.makeCredentialProvider(settings: settings)
        let speechCredentialProvider = AIServiceComposition.makeSpeechCredentialProvider(
            settings: settings
        )
        let teleprompterSettings = TeleprompterSettings()
        let diagnostics = ConversationTelemetryStore(capacity: 1_000)
        let controller = VoiceConversationController(
            dependencies: .live(
                settings: settings,
                credentialProvider: credentialProvider,
                telemetry: diagnostics
            )
        )
        let gameController = TextAdventureController(
            provider: LiveTextAdventureProvider(
                settings: settings,
                credentialProvider: credentialProvider
            ),
            preparationProvider: LiveTextAdventureRunPreparationProvider(
                settings: settings,
                credentialProvider: credentialProvider
            ),
            reduceMotion: { UIAccessibility.isReduceMotionEnabled }
        )
        let teleprompterController = TeleprompterController(
            script: try? TeleprompterScript(teleprompterSettings.scriptDraft),
            dependencies: LiveSpeechInputComposition.makeTeleprompterDependencies(
                configurationProvider: {
                    TeleprompterSpeechConfiguration(
                        resourceID: settings.asrResourceID,
                        language: settings.asrLanguage,
                        hotwords: settings.hotwords
                    )
                },
                speechCredentialProvider: speechCredentialProvider,
                cloudSpeechRecognitionAllowed: {
                    teleprompterSettings.allowsCloudSpeechRecognition
                }
            )
        )
        _teleprompterSettings = StateObject(wrappedValue: teleprompterSettings)
        _diagnostics = StateObject(wrappedValue: diagnostics)
        _conversationController = StateObject(wrappedValue: controller)
        _textAdventureController = StateObject(wrappedValue: gameController)
        _teleprompterController = StateObject(wrappedValue: teleprompterController)
        _runtime = StateObject(
            wrappedValue: Self.makeRuntime(
                controller: controller,
                textAdventureController: gameController,
                teleprompterController: teleprompterController
            )
        )
    }

    @MainActor
    static func makeAISettings() -> AISettings {
        // The production App target explicitly links the detector product;
        // isolated settings fixtures remain fail-closed unless they opt in.
        AISettings(speechInputAvailability: .productionDetectorAvailable)
    }

    @MainActor
    private static func makeRuntime(
        controller: VoiceConversationController,
        textAdventureController: TextAdventureController,
        teleprompterController: TeleprompterController
    ) -> ExperienceRuntime {
        do {
            return try ExperienceRuntime(
                validating: DemoExperienceComposition.sessions(
                    controller: controller,
                    textAdventureController: textAdventureController,
                    teleprompterController: teleprompterController
                )
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
                .environmentObject(teleprompterSettings)
                .environmentObject(diagnostics)
                .task(priority: .userInitiated) {
                    diagnostics.record(category: "app", message: "launch")
                    await cameraController.prepare()
                }
                .onChange(of: teleprompterSettings.scriptConfigurationRevision) { _, _ in
                    let script = teleprompterSettings.scriptDraft
                    Task { await teleprompterController.loadScript(script) }
                }
                .onChange(of: teleprompterSettings.allowsCloudSpeechRecognition) { _, isAllowed in
                    Task {
                        await teleprompterController.updateCloudSpeechRecognitionConsent(isAllowed)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            diagnostics.record(category: "lifecycle", message: String(describing: phase))
            cameraController.handle(scenePhase: phase)
            switch phase {
            case .background:
                conversationController.updateHostLifecycle(.background)
                textAdventureController.updateHostLifecycle(.background)
                teleprompterController.updateHostLifecycle(.background)
            case .active:
                conversationController.updateHostLifecycle(.active)
                textAdventureController.updateHostLifecycle(.active)
                teleprompterController.updateHostLifecycle(.active)
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

    static func sessions(
        controller: VoiceConversationController,
        textAdventureController: TextAdventureController? = nil,
        teleprompterController: TeleprompterController? = nil
    ) -> [any ExperienceSession] {
        let gameController = textAdventureController ?? TextAdventureController(
            provider: UnavailableTextAdventureProvider(),
            preparationProvider: UnavailableTextAdventureRunPreparationProvider()
        )
        let promptController = teleprompterController ?? TeleprompterController(
            dependencies: TeleprompterDependencies(
                prepareSpeechSession: { throw ServerCredentialError.transportNotConfigured },
                requestMicrophonePermission: { false },
                cloudSpeechRecognitionAllowed: { false }
            )
        )
        return [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience(),
            AIConversationExperience(
                controller: controller,
                providerDetail: aiProviderDetail
            ),
            TextAdventureExperience(
                controller: gameController,
                providerDetail: "博查灵感搜索 → DeepSeek 故事框架与回合"
            ),
            TeleprompterExperience(controller: promptController)
        ]
    }
}

@MainActor
private final class UnavailableTextAdventureProvider: TextAdventureTurnProvider {
    func proposeTurn(_ request: TextAdventureTurnRequest) async throws -> TextAdventureCheckpoint {
        throw ServerCredentialError.transportNotConfigured
    }
}

@MainActor
private final class UnavailableTextAdventureRunPreparationProvider:
    TextAdventureRunPreparationProvider {
    func prepareTrendSeed(
        _ request: TextAdventureTrendPreparationRequest
    ) async throws -> TextAdventureTrendSeed {
        .reviewedFallback(seed: request.seed)
    }

    func prepareFramework(
        _ request: TextAdventureFrameworkPreparationRequest
    ) async throws -> TextAdventurePreparedRun {
        throw ServerCredentialError.transportNotConfigured
    }
}
