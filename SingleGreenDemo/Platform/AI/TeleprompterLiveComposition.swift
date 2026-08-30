import AVFoundation
import SingleGreenConversationAdapters
import SingleGreenGlassesKit
import VoiceChatCore

struct TeleprompterSpeechConfiguration: Equatable, Sendable {
    let resourceID: String
    let language: String
    let hotwords: [String]
}

enum LiveSpeechInputComposition {
    static func requestMicrophonePermission() async -> Bool {
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
    }

    @MainActor
    static func makeTeleprompterDependencies(
        configurationProvider: @escaping @MainActor () -> TeleprompterSpeechConfiguration,
        speechCredentialProvider: any SpeechCredentialProvider,
        cloudSpeechRecognitionAllowed: @escaping () -> Bool
    ) -> TeleprompterDependencies {
        return TeleprompterDependencies(
            prepareSpeechSession: {
                let configuration = configurationProvider()
                let lease: SpeechCredentialLease
                do {
                    lease = try await speechCredentialProvider.speechLease()
                } catch {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "语音识别暂不可用。",
                        failureCode: .preparationUnavailable
                    )
                }
                guard lease.isUsable(at: .now, minimumRemainingLifetime: 0),
                      !configuration.resourceID.trimmed.isEmpty else {
                    throw ConversationPreparationFailure(
                        userSafeMessage: "请先在设置中完成语音识别配置。",
                        failureCode: .configurationMissing
                    )
                }
                let session = ASRSession(config: .init(
                    apiKey: lease.apiKey.trimmed,
                    resourceID: configuration.resourceID.trimmed,
                    language: configuration.language,
                    hotwords: configuration.hotwords
                ))
                return VoiceChatSpeechRecognitionAdapter(session: session)
            },
            requestMicrophonePermission: requestMicrophonePermission,
            cloudSpeechRecognitionAllowed: cloudSpeechRecognitionAllowed
        )
    }
}
