import Foundation
import SingleGreenGlassesKit
import VoiceChatCore

protocol VoiceChatASRSessionBase: Sendable {
    var events: AsyncStream<ASRSession.Event> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

extension ASRSession: VoiceChatASRSessionBase {}

/// Adapts an already configured VoiceChatCore session to the provider-neutral
/// glasses speech-recognition contract.
public actor VoiceChatSpeechRecognitionAdapter: SpeechRecognitionSession {
    public nonisolated let events: AsyncStream<SpeechRecognitionEvent>

    private let base: any VoiceChatASRSessionBase
    private var bridgeTask: Task<Void, Never>?

    public init(session: ASRSession) {
        self.init(base: session)
    }

    init(base: any VoiceChatASRSessionBase) {
        self.base = base

        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        bridgeTask = Task {
            for await event in base.events {
                switch event {
                case .transcript(let text):
                    continuation.yield(.transcript(text))
                case .utterance(let text):
                    continuation.yield(.utterance(text))
                case .level(let value):
                    continuation.yield(.level(value))
                case .state(.finished):
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                case .state(.failed(let failure)), .error(let failure):
                    continuation.yield(.failed(Self.failure(forCoreFailure: failure)))
                    continuation.finish()
                    return
                case .state:
                    break
                }
            }
            continuation.finish()
        }
    }

    deinit {
        bridgeTask?.cancel()
    }

    public func start() async throws {
        do {
            try await base.start()
        } catch {
            throw Self.failure(forStartError: error)
        }
    }

    public func finish() async {
        await base.finish()
    }

    public func cancel() async {
        await base.cancel()
    }

    static func failure(forStartError error: Error) -> SpeechRecognitionFailure {
        guard let failure = error as? ASRFailure else {
            return SpeechRecognitionFailure(code: .unknown)
        }
        return Self.failure(forCoreFailure: failure)
    }

    static func failure(forCoreFailure failure: ASRFailure) -> SpeechRecognitionFailure {
        let code: SpeechRecognitionFailure.Code = switch failure.code {
        case .unauthorized: .unauthorized
        case .networkUnavailable: .networkUnavailable
        case .timeout: .timeout
        case .connectionLost: .connectionLost
        case .protocolFailure: .protocolFailure
        case .audioInterrupted: .audioInterrupted
        case .audioUnavailable: .audioUnavailable
        case .voiceActivityUnavailable: .voiceActivityUnavailable
        case .voiceActivityProcessingFailed: .voiceActivityProcessingFailed
        case .audioCaptureOverrun: .audioCaptureOverrun
        case .uploadBackpressureExceeded: .uploadBackpressureExceeded
        case .unknown: .unknown
        }
        return SpeechRecognitionFailure(code: code, userSafeMessage: failure.userSafeMessage)
    }

    static func failure(
        forAudioSystemEvent event: AudioCapture.AudioSystemEvent
    ) -> SpeechRecognitionFailure? {
        ASRFailure.audioSystemEvent(event).map(failure(forCoreFailure:))
    }
}
