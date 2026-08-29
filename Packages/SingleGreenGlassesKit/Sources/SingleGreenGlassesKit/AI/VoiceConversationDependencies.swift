import Foundation
import StreamingTextKit

public struct VoiceConversationInputDependencies {
    public let inputMode: () -> SpeechInputMode
    public let voiceActivatedInputAvailable: () -> Bool
    public let prepareSpeechInput: (SpeechInputMode) async throws -> PreparedSpeechInputSession
    public let requestMicrophonePermission: () async -> Bool

    public init(
        inputMode: @escaping () -> SpeechInputMode,
        voiceActivatedInputAvailable: @escaping () -> Bool,
        prepareSpeechInput: @escaping (SpeechInputMode) async throws -> PreparedSpeechInputSession,
        requestMicrophonePermission: @escaping () async -> Bool
    ) {
        self.inputMode = inputMode
        self.voiceActivatedInputAvailable = voiceActivatedInputAvailable
        self.prepareSpeechInput = prepareSpeechInput
        self.requestMicrophonePermission = requestMicrophonePermission
    }
}

public struct VoiceConversationAgentDependencies {
    public let prepareAgent: () async throws -> PreparedConversationAgent

    public init(
        prepareAgent: @escaping () async throws -> PreparedConversationAgent
    ) {
        self.prepareAgent = prepareAgent
    }
}

public struct VoiceConversationPresentationDependencies {
    public let sleep: (Duration) async throws -> Void
    public let reduceMotion: () -> Bool
    public let streamingTextPolicy: TypewriterPolicy
    public let copy: ConversationPresentationCopy

    public init(
        sleep: @escaping (Duration) async throws -> Void,
        reduceMotion: @escaping () -> Bool = { false },
        streamingTextPolicy: TypewriterPolicy = .comfortableReading,
        copy: ConversationPresentationCopy
    ) {
        self.sleep = sleep
        self.reduceMotion = reduceMotion
        self.streamingTextPolicy = streamingTextPolicy
        self.copy = copy
    }
}

public struct VoiceConversationObservabilityDependencies {
    public let telemetry: any ConversationTelemetrySink
    /// Monotonic nanoseconds used only for relative privacy-safe durations.
    public let monotonicNow: () -> UInt64

    public init(
        telemetry: any ConversationTelemetrySink = NoopConversationTelemetry(),
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.telemetry = telemetry
        self.monotonicNow = monotonicNow
    }
}

public struct VoiceConversationDependencies {
    public let input: VoiceConversationInputDependencies
    public let agent: VoiceConversationAgentDependencies
    public let presentation: VoiceConversationPresentationDependencies
    public let observability: VoiceConversationObservabilityDependencies

    public var inputMode: () -> SpeechInputMode { input.inputMode }
    public var voiceActivatedInputAvailable: () -> Bool { input.voiceActivatedInputAvailable }
    public var prepareSpeechInput: (SpeechInputMode) async throws -> PreparedSpeechInputSession {
        input.prepareSpeechInput
    }
    public var prepareAgent: () async throws -> PreparedConversationAgent { agent.prepareAgent }
    public var requestMicrophonePermission: () async -> Bool { input.requestMicrophonePermission }
    public var sleep: (Duration) async throws -> Void { presentation.sleep }
    public var reduceMotion: () -> Bool { presentation.reduceMotion }
    public var streamingTextPolicy: TypewriterPolicy { presentation.streamingTextPolicy }
    public var telemetry: any ConversationTelemetrySink { observability.telemetry }
    public var presentationCopy: ConversationPresentationCopy { presentation.copy }
    /// Monotonic nanoseconds used only for relative privacy-safe durations.
    public var monotonicNow: () -> UInt64 { observability.monotonicNow }

    public init(
        input: VoiceConversationInputDependencies,
        agent: VoiceConversationAgentDependencies,
        presentation: VoiceConversationPresentationDependencies,
        observability: VoiceConversationObservabilityDependencies = .init()
    ) {
        self.input = input
        self.agent = agent
        self.presentation = presentation
        self.observability = observability
    }

    public init(
        inputMode: @escaping () -> SpeechInputMode,
        voiceActivatedInputAvailable: @escaping () -> Bool,
        prepareSpeechInput: @escaping (SpeechInputMode) async throws -> PreparedSpeechInputSession,
        prepareAgent: @escaping () async throws -> PreparedConversationAgent,
        requestMicrophonePermission: @escaping () async -> Bool,
        sleep: @escaping (Duration) async throws -> Void,
        reduceMotion: @escaping () -> Bool = { false },
        streamingTextPolicy: TypewriterPolicy = .comfortableReading,
        telemetry: any ConversationTelemetrySink = NoopConversationTelemetry(),
        presentationCopy: ConversationPresentationCopy,
        monotonicNow: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.init(
            input: VoiceConversationInputDependencies(
                inputMode: inputMode,
                voiceActivatedInputAvailable: voiceActivatedInputAvailable,
                prepareSpeechInput: prepareSpeechInput,
                requestMicrophonePermission: requestMicrophonePermission
            ),
            agent: VoiceConversationAgentDependencies(prepareAgent: prepareAgent),
            presentation: VoiceConversationPresentationDependencies(
                sleep: sleep,
                reduceMotion: reduceMotion,
                streamingTextPolicy: streamingTextPolicy,
                copy: presentationCopy
            ),
            observability: VoiceConversationObservabilityDependencies(
                telemetry: telemetry,
                monotonicNow: monotonicNow
            )
        )
    }
}

public struct ConversationPresentationCopy: Equatable, Sendable {
    public let voiceActivatedUnavailable: String
    public let microphonePermissionDenied: String
    public let speechRecognitionUnavailable: String
    public let noSpeech: String
    public let replyPreparationUnavailable: String
    public let emptyReply: String
    public let inconsistentReplyStream: String
    public let incompleteReplyStream: String
    public let unexpectedReplyFailure: String
    public let interruptedReplyPrefix: String
    public let failedReplyPrefix: String
    public let contextCommitFailed: String

    public init(
        voiceActivatedUnavailable: String,
        microphonePermissionDenied: String,
        speechRecognitionUnavailable: String,
        noSpeech: String,
        replyPreparationUnavailable: String,
        emptyReply: String,
        inconsistentReplyStream: String,
        incompleteReplyStream: String,
        unexpectedReplyFailure: String,
        interruptedReplyPrefix: String,
        failedReplyPrefix: String,
        contextCommitFailed: String
    ) {
        self.voiceActivatedUnavailable = voiceActivatedUnavailable
        self.microphonePermissionDenied = microphonePermissionDenied
        self.speechRecognitionUnavailable = speechRecognitionUnavailable
        self.noSpeech = noSpeech
        self.replyPreparationUnavailable = replyPreparationUnavailable
        self.emptyReply = emptyReply
        self.inconsistentReplyStream = inconsistentReplyStream
        self.incompleteReplyStream = incompleteReplyStream
        self.unexpectedReplyFailure = unexpectedReplyFailure
        self.interruptedReplyPrefix = interruptedReplyPrefix
        self.failedReplyPrefix = failedReplyPrefix
        self.contextCommitFailed = contextCommitFailed
    }
}

public extension TypewriterPolicy {
    /// 约 6–7 字/秒，保留清晰的逐字阅读感。
    static let comfortableReading = TypewriterPolicy(
        tickIntervalMilliseconds: 150,
        shortBacklogLimit: 2_000,
        mediumBacklogLimit: 2_000,
        mediumBatchSize: 1,
        minimumLargeBatchSize: 1,
        catchUpTickBudget: 2_000
    )
}
