import SingleGreenConversationAdapters
import SingleGreenGlassesKit
import VoiceChatCore
import WebRTCVoiceActivityDetection

/// App-owned production composition for hands-free speech input. Constructing
/// this graph is intentionally inert: microphone capture and ASR transport do
/// not start until the returned session receives `arm()`.
enum ProductionVoiceActivatedSessionFactory {
    /// Mode 2 balances rejecting common mobile ambient noise against clipping
    /// conversational speech. The choice remains an App policy rather than a
    /// detector-package default or a glasses-core concern.
    static let aggressiveness: WebRTCVADAggressiveness = .aggressive
    static let policy: VoiceActivatedASRPolicy = .standard

    static func make(
        configuration: SpeechProviderConfiguration,
        diagnostics: VoiceActivatedASRDiagnosticsObserver? = nil
    ) throws -> any VoiceActivatedSpeechRecognitionSession {
        let initialSession = try makeCoreSession(
            configuration: configuration,
            diagnostics: diagnostics
        )
        let supervisor = VoiceActivatedASRSessionSupervisor(
            initialSession: initialSession,
            policy: .disabled(disposition: .retryableFailure),
            recoveryFactory: {
                try makeCoreSession(
                    configuration: configuration,
                    diagnostics: diagnostics
                )
            }
        )
        return VoiceChatVoiceActivatedSpeechRecognitionAdapter(supervisor: supervisor)
    }

    static func makeCoreSession(
        configuration: SpeechProviderConfiguration,
        diagnostics: VoiceActivatedASRDiagnosticsObserver? = nil
    ) throws -> VoiceActivatedASRSession {
        let detector = try WebRTCVoiceActivityDetector(
            aggressiveness: aggressiveness
        )
        return VoiceActivatedASRSession(
            config: ASRSession.Config(
                apiKey: configuration.apiKey,
                resourceID: configuration.resourceID,
                language: configuration.language,
                hotwords: configuration.hotwords
            ),
            detector: detector,
            policy: policy,
            diagnostics: diagnostics
        )
    }
}
