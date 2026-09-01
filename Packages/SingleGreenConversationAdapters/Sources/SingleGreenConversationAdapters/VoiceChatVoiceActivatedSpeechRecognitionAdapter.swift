import Foundation
import SingleGreenGlassesKit
import VoiceChatCore

protocol VoiceChatVoiceActivatedASRSessionBase: Sendable {
    var events: AsyncStream<VoiceActivatedASREvent> { get }
    func arm() async throws
    func finish() async
    func cancel() async
}

extension VoiceActivatedASRSession: VoiceChatVoiceActivatedASRSessionBase {}
extension VoiceActivatedASRSessionSupervisor: VoiceChatVoiceActivatedASRSessionBase {}

/// Adapts one configured VoiceChatCore local-VAD session to the glasses port.
/// This boundary deduplicates lifecycle phases and emits at most one terminal.
public actor VoiceChatVoiceActivatedSpeechRecognitionAdapter:
    VoiceActivatedSpeechRecognitionSession {
    public nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>

    private let base: any VoiceChatVoiceActivatedASRSessionBase
    private let eventBridge: VoiceActivatedASREventBridge
    private var bridgeTask: Task<Void, Never>?
    private var hasCancelledBase = false

    public init(session: VoiceActivatedASRSession) {
        self.init(base: session)
    }

    public init(supervisor: VoiceActivatedASRSessionSupervisor) {
        self.init(base: supervisor)
    }

    init(base: any VoiceChatVoiceActivatedASRSessionBase) {
        self.base = base
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        let eventBridge = VoiceActivatedASREventBridge(continuation: continuation)
        self.eventBridge = eventBridge
        bridgeTask = Task { [base, eventBridge] in
            for await event in base.events {
                guard !Task.isCancelled else { return }
                guard await eventBridge.receive(event) else { return }
            }
            await eventBridge.finishWithoutSyntheticTerminal()
        }
    }

    deinit {
        bridgeTask?.cancel()
    }

    public func arm() async throws {
        do {
            try await base.arm()
        } catch {
            throw VoiceChatSpeechRecognitionAdapter.failure(forStartError: error)
        }
    }

    public func finish() async {
        guard await eventBridge.isActive else { return }
        await base.finish()
    }

    public func cancel() async {
        guard !hasCancelledBase else { return }
        hasCancelledBase = true
        bridgeTask?.cancel()
        bridgeTask = nil
        await eventBridge.terminate()
        await base.cancel()
    }
}

private actor VoiceActivatedASREventBridge {
    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation
    private var emittedArmed = false
    private var emittedSpeechStarted = false
    private var emittedFinalizing = false
    private(set) var isActive = true

    init(continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    /// Returns whether the source observation should continue.
    func receive(_ event: VoiceActivatedASREvent) -> Bool {
        guard isActive else { return false }
        switch event {
        case .state(.armed):
            guard !emittedArmed else { return true }
            emittedArmed = true
            continuation.yield(.phase(.armed))
        case .state(.openingRecognizer):
            guard !emittedSpeechStarted else { return true }
            emittedSpeechStarted = true
            continuation.yield(.phase(.speechStarted))
        case .state(.draining(let reason)), .state(.finalizing(let reason)):
            guard !emittedFinalizing else { return true }
            emittedFinalizing = true
            continuation.yield(.phase(.finalizing(Self.endpointReason(for: reason))))
        case .state(.finished):
            continuation.yield(.finished)
            terminate()
        case .state(.failed(let failure)):
            continuation.yield(.failed(
                VoiceChatSpeechRecognitionAdapter.failure(forCoreFailure: failure)
            ))
            terminate()
        case .state:
            break
        case .transcript(let text):
            continuation.yield(.transcript(text))
        case .utterance(let text):
            continuation.yield(.utterance(text))
        case .level(let value):
            continuation.yield(.level(value))
        case .noSpeech:
            continuation.yield(.noSpeech)
            terminate()
        }
        return isActive
    }

    func finishWithoutSyntheticTerminal() {
        terminate()
    }

    func terminate() {
        guard isActive else { return }
        isActive = false
        continuation.finish()
    }

    private static func endpointReason(
        for reason: VoiceActivatedEndpointReason
    ) -> VoiceEndpointReason {
        switch reason {
        case .silence: .silence
        case .maximumDuration: .maximumDuration
        case .manual: .manual
        }
    }
}
