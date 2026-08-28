import Foundation

// MARK: - Input contracts

public enum SpeechInputMode: String, Equatable, Sendable {
    case pushToTalk
    case voiceActivated
}

// MARK: - ASR port

/// Provider-neutral ASR failure. `userSafeMessage` may contain only reviewed,
/// static copy suitable for direct presentation; provider payloads and raw
/// framework error descriptions do not belong in this contract.
public struct SpeechRecognitionFailure: Error, Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case unauthorized
        case networkUnavailable
        case timeout
        case connectionLost
        case audioInterrupted
        case audioUnavailable
        case voiceActivityUnavailable
        case voiceActivityProcessingFailed
        case audioCaptureOverrun
        case uploadBackpressureExceeded
        case protocolFailure
        case unknown
    }

    public let code: Code
    public let userSafeMessage: String?

    public init(code: Code, userSafeMessage: String? = nil) {
        self.code = code
        self.userSafeMessage = userSafeMessage
    }
}

public enum SpeechRecognitionEvent: Equatable, Sendable {
    case transcript(String)
    case utterance(String)
    case level(Float)
    case finished
    case failed(SpeechRecognitionFailure)
}

public protocol SpeechRecognitionSession: AnyObject, Sendable {
    var events: AsyncStream<SpeechRecognitionEvent> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

// MARK: - Voice-activated ASR port

public enum VoiceEndpointReason: Equatable, Sendable {
    case silence
    case maximumDuration
    case manual
}

public enum VoiceActivatedRecognitionPhase: Equatable, Sendable {
    /// Local microphone capture and VAD only. No recognizer connection exists.
    case armed
    /// Local onset was accepted and the recognizer may now connect.
    case speechStarted
    case finalizing(VoiceEndpointReason)
}

public enum VoiceActivatedRecognitionEvent: Equatable, Sendable {
    case phase(VoiceActivatedRecognitionPhase)
    case transcript(String)
    case utterance(String)
    case level(Float)
    case noSpeech
    case finished
    case failed(SpeechRecognitionFailure)
}

/// A one-utterance, provider-neutral input session whose implementation must
/// keep recognizer networking and audio upload closed until local speech onset.
public protocol VoiceActivatedSpeechRecognitionSession: AnyObject, Sendable {
    var events: AsyncStream<VoiceActivatedRecognitionEvent> { get }
    func arm() async throws
    func finish() async
    func cancel() async
}

/// A host-prepared, already configured input session. Provider configuration
/// and authorization remain on the host side of this boundary.
public enum PreparedSpeechInputSession: Sendable {
    case pushToTalk(any SpeechRecognitionSession)
    case voiceActivated(any VoiceActivatedSpeechRecognitionSession)

    public var mode: SpeechInputMode {
        switch self {
        case .pushToTalk: .pushToTalk
        case .voiceActivated: .voiceActivated
        }
    }

    public func cancel() async {
        switch self {
        case .pushToTalk(let session): await session.cancel()
        case .voiceActivated(let session): await session.cancel()
        }
    }
}

// MARK: - Agent port

public enum ConversationToolActivity: Equatable, Sendable {
    case externalInformationLookup
}

public enum ConversationAgentEvent: Equatable, Sendable {
    case transaction(ConversationAgentTransactionToken)
    case toolActivity(ConversationToolActivity)
    case contentDelta(String)
    case completed(String)
}

/// Stable, opaque host identity for the Agent's provider/model/tool context.
/// The glasses core uses equality only and never interprets provider settings.
public struct ConversationAgentContextIdentity: Hashable, Sendable {
    private let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Opaque identity used to acknowledge one finalized Agent context transaction.
public struct ConversationAgentTransactionToken: Hashable, Sendable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

public enum ConversationAgentStreamError: Error, LocalizedError, Sendable, Equatable {
    /// Messages in these typed cases must be reviewed host presentation copy,
    /// never raw provider payloads or arbitrary `localizedDescription` values.
    case discardPartial(String)
    case failed(String, ConversationFailureCode)

    public var shouldDiscardPartial: Bool {
        switch self {
        case .discardPartial: true
        case .failed: false
        }
    }

    public var failureCode: ConversationFailureCode {
        switch self {
        case .discardPartial: .interrupted
        case .failed(_, let code): code
        }
    }

    public var errorDescription: String? {
        switch self {
        case .discardPartial(let message): return message
        case .failed(let message, _): return message
        }
    }
}

public protocol ConversationAgent: Sendable {
    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error>
    /// Makes the staged transaction visible to subsequent Agent turns.
    ///
    /// Implementations must either avoid suspension after mutating context or
    /// make `abort(_:)` roll back this exact token until the next transaction
    /// begins. This keeps host cancellation from leaving a hidden committed turn.
    func commit(_ token: ConversationAgentTransactionToken) async throws
    /// Discards a staged transaction, or rolls back that same transaction if its
    /// commit finished internally but had not yet been accepted by the host.
    /// The operation must be idempotent and must not affect earlier history.
    func abort(_ token: ConversationAgentTransactionToken) async
    func clearContext() async
}

public struct PreparedConversationAgent: Sendable {
    public let contextIdentity: ConversationAgentContextIdentity
    public let agent: any ConversationAgent
    private let discardPreparation: @Sendable () async -> Void

    public init(
        contextIdentity: ConversationAgentContextIdentity,
        agent: any ConversationAgent,
        discardPreparation: @escaping @Sendable () async -> Void = {}
    ) {
        self.contextIdentity = contextIdentity
        self.agent = agent
        self.discardPreparation = discardPreparation
    }

    /// Releases only resources owned by this unused preparation. Hosts must
    /// make this safe when another handle with the same `contextIdentity` is
    /// already retained; it must not clear that logical conversation context.
    public func discard() async {
        await discardPreparation()
    }
}

/// A reviewed host-side preparation failure that is safe to present directly.
public struct ConversationPreparationFailure: Error, Equatable, Sendable {
    public let userSafeMessage: String
    public let failureCode: ConversationFailureCode

    public init(
        userSafeMessage: String,
        failureCode: ConversationFailureCode
    ) {
        self.userSafeMessage = userSafeMessage
        self.failureCode = failureCode
    }
}

public extension ConversationAgent {
    /// Stateless test or local agents can use the compatibility no-op acknowledgement.
    func commit(_ token: ConversationAgentTransactionToken) async throws {}
    func abort(_ token: ConversationAgentTransactionToken) async {}
}
