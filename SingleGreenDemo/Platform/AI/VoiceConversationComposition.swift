import Foundation
import SingleGreenGlassesKit

@MainActor
struct VoiceConversationComposition {
    let resolver: ConversationPreparationResolver
    let requestMicrophonePermission: () async -> Bool
    let sleep: (Duration) async throws -> Void
    let reduceMotion: () -> Bool
    let telemetry: any ConversationTelemetrySink
    let presentationCopy: ConversationPresentationCopy
    let monotonicNow: () -> UInt64

    init(
        resolver: ConversationPreparationResolver,
        requestMicrophonePermission: @escaping () async -> Bool,
        sleep: @escaping (Duration) async throws -> Void,
        reduceMotion: @escaping () -> Bool,
        telemetry: any ConversationTelemetrySink,
        presentationCopy: ConversationPresentationCopy,
        monotonicNow: @escaping () -> UInt64
    ) {
        self.resolver = resolver
        self.requestMicrophonePermission = requestMicrophonePermission
        self.sleep = sleep
        self.reduceMotion = reduceMotion
        self.telemetry = telemetry
        self.presentationCopy = presentationCopy
        self.monotonicNow = monotonicNow
    }

    var inputDependencies: VoiceConversationInputDependencies {
        VoiceConversationInputDependencies(
            inputMode: { resolver.requestedInputMode },
            voiceActivatedInputAvailable: { resolver.voiceActivatedInputAvailable },
            prepareSpeechInput: { mode in
                try await resolver.prepareSpeechInput(mode: mode)
            },
            requestMicrophonePermission: requestMicrophonePermission
        )
    }

    var agentDependencies: VoiceConversationAgentDependencies {
        VoiceConversationAgentDependencies(
            prepareAgent: {
                try await resolver.prepareAgent()
            }
        )
    }

    var presentationDependencies: VoiceConversationPresentationDependencies {
        VoiceConversationPresentationDependencies(
            sleep: sleep,
            reduceMotion: reduceMotion,
            copy: presentationCopy
        )
    }

    var observabilityDependencies: VoiceConversationObservabilityDependencies {
        VoiceConversationObservabilityDependencies(
            telemetry: telemetry,
            monotonicNow: monotonicNow
        )
    }

    var dependencies: VoiceConversationDependencies {
        VoiceConversationDependencies(
            input: inputDependencies,
            agent: agentDependencies,
            presentation: presentationDependencies,
            observability: observabilityDependencies
        )
    }
}
