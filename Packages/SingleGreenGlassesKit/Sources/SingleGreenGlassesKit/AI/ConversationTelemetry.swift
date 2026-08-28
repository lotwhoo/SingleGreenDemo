import Foundation

/// Privacy-safe operational phases. Transcript, answer, tool arguments, provider
/// payloads, credentials, and stable user/device identifiers are intentionally
/// absent from this contract.
public enum ConversationTelemetryPhase: String, Equatable, Sendable {
    case input
    case reply
    case display
    case lifecycle
    case preparation
}

public enum ConversationTelemetryOutcome: String, Equatable, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case suspended
}

public enum ConversationFailureCode: String, Error, Equatable, Sendable {
    case configurationMissing
    case microphonePermissionDenied
    case unauthorized
    case networkUnavailable
    case timeout
    case connectionLost
    case audioInterrupted
    case audioUnavailable
    case protocolFailure
    case interrupted
    case incompleteStream
    case contextCommitFailed
    case preparationUnavailable
    case unknown
}

public struct ConversationTelemetryEvent: Equatable, Sendable {
    public let phase: ConversationTelemetryPhase
    public let outcome: ConversationTelemetryOutcome
    public let elapsedMilliseconds: UInt64
    public let failureCode: ConversationFailureCode?

    public init(
        phase: ConversationTelemetryPhase,
        outcome: ConversationTelemetryOutcome,
        elapsedMilliseconds: UInt64,
        failureCode: ConversationFailureCode? = nil
    ) {
        self.phase = phase
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.failureCode = failureCode
    }
}

@MainActor
public protocol ConversationTelemetrySink: AnyObject {
    func record(_ event: ConversationTelemetryEvent)
}

@MainActor
public final class NoopConversationTelemetry: ConversationTelemetrySink {
    public nonisolated init() {}
    public func record(_ event: ConversationTelemetryEvent) {}
}
