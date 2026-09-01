import SingleGreenGlassesKit
import VoiceChatCore

protocol VoiceChatASRSessionSupervisorBase: Sendable {
    var events: AsyncStream<ASRSessionSupervisorEvent> { get }
    func start() async throws
    func finish() async
    func cancel() async
}

extension ASRSessionSupervisor: VoiceChatASRSessionSupervisorBase {}

/// Maps typed supervision outcomes to the stable glasses speech-recognition port. The App chooses
/// `.manualControl` for teleprompter and `.retryableFailure` for conversation when constructing the
/// supervisor; feature controllers retain those fixed fallback semantics without parsing errors.
public actor VoiceChatSupervisedSpeechRecognitionAdapter: SpeechRecognitionSession {
    public nonisolated let events: AsyncStream<SpeechRecognitionEvent>

    private let base: any VoiceChatASRSessionSupervisorBase
    private var bridgeTask: Task<Void, Never>?
    private var hasCancelledBase = false

    public init(supervisor: ASRSessionSupervisor) {
        self.init(base: supervisor)
    }

    init(base: any VoiceChatASRSessionSupervisorBase) {
        self.base = base
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        bridgeTask = Task {
            for await event in base.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .transcript(let text):
                    continuation.yield(.transcript(text))
                case .utterance(let text):
                    continuation.yield(.utterance(text))
                case .level(let value):
                    continuation.yield(.level(value))
                case .state(.completed):
                    continuation.yield(.finished)
                    continuation.finish()
                    return
                case .state(.degraded(let degradation)):
                    continuation.yield(.failed(
                        VoiceChatSpeechRecognitionAdapter.failure(
                            forCoreFailure: degradation.failure
                        )
                    ))
                    continuation.finish()
                    return
                case .state(.failed(let failure)):
                    continuation.yield(.failed(
                        VoiceChatSpeechRecognitionAdapter.failure(forCoreFailure: failure)
                    ))
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
        } catch let degradation as ASRSessionDegradation {
            throw VoiceChatSpeechRecognitionAdapter.failure(
                forCoreFailure: degradation.failure
            )
        } catch let failure as ASRFailure {
            throw VoiceChatSpeechRecognitionAdapter.failure(forCoreFailure: failure)
        } catch {
            throw SpeechRecognitionFailure(code: .unknown)
        }
    }

    public func finish() async {
        await base.finish()
    }

    public func cancel() async {
        guard !hasCancelledBase else { return }
        hasCancelledBase = true
        bridgeTask?.cancel()
        bridgeTask = nil
        await base.cancel()
    }
}
