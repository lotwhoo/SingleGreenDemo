import Foundation
import StreamingTextKit

public struct VoiceConversationDependencies {
    public let inputMode: () -> SpeechInputMode
    public let voiceActivatedInputAvailable: () -> Bool
    public let prepareSpeechInput: (SpeechInputMode) async throws -> PreparedSpeechInputSession
    public let prepareAgent: () async throws -> PreparedConversationAgent
    public let requestMicrophonePermission: () async -> Bool
    public let sleep: (Duration) async throws -> Void
    public let reduceMotion: () -> Bool
    public let streamingTextPolicy: TypewriterPolicy
    public let telemetry: any ConversationTelemetrySink
    public let presentationCopy: ConversationPresentationCopy
    /// Monotonic nanoseconds used only for relative privacy-safe durations.
    public let monotonicNow: () -> UInt64

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
        self.inputMode = inputMode
        self.voiceActivatedInputAvailable = voiceActivatedInputAvailable
        self.prepareSpeechInput = prepareSpeechInput
        self.prepareAgent = prepareAgent
        self.requestMicrophonePermission = requestMicrophonePermission
        self.sleep = sleep
        self.reduceMotion = reduceMotion
        self.streamingTextPolicy = streamingTextPolicy
        self.telemetry = telemetry
        self.presentationCopy = presentationCopy
        self.monotonicNow = monotonicNow
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
