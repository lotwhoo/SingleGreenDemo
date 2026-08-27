import AVFoundation
import Foundation
import StreamingTextKit
import UIKit

struct VoiceConversationDependencies {
    var configuration: () -> AIConversationConfiguration
    var makeSpeechSession: (SpeechRecognitionConfiguration) -> any SpeechRecognitionSession
    var makeAgent: (ConversationAgentConfiguration) -> any ConversationAgent
    var requestMicrophonePermission: () async -> Bool
    var now: () -> Date
    var sleep: (Duration) async throws -> Void
    var reduceMotion: () -> Bool = { false }
    var streamingTextPolicy: TypewriterPolicy = .standard

    @MainActor
    static func live(settings: AISettings) -> Self {
        Self(
            configuration: {
                AIConversationConfiguration(
                    speechAPIKey: settings.speechAPIKey,
                    asrResourceID: settings.asrResourceID,
                    asrLanguage: settings.asrLanguage,
                    hotwords: settings.hotwords,
                    handsFree: settings.handsFree,
                    llmAPIKey: settings.llmAPIKey,
                    llmModel: settings.llmModel,
                    enableSearch: settings.enableSearch,
                    bochaAPIKey: settings.bochaAPIKey
                )
            },
            makeSpeechSession: { configuration in
                VoiceChatSpeechRecognitionSession(configuration: configuration)
            },
            makeAgent: { configuration in
                LLMKitConversationAgent(configuration: configuration)
            },
            requestMicrophonePermission: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:
                    return true
                case .denied:
                    return false
                case .undetermined:
                    return await withCheckedContinuation { continuation in
                        AVAudioApplication.requestRecordPermission {
                            continuation.resume(returning: $0)
                        }
                    }
                @unknown default:
                    return false
                }
            },
            now: { .now },
            sleep: { duration in try await Task.sleep(for: duration) },
            reduceMotion: { UIAccessibility.isReduceMotionEnabled }
        )
    }
}
