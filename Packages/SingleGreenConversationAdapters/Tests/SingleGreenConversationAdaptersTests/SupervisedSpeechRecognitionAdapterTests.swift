import SingleGreenGlassesKit
import VoiceChatCore
import XCTest
@testable import SingleGreenConversationAdapters

final class SupervisedSpeechRecognitionAdapterTests: XCTestCase {
    func testMapsPayloadsAndCompletedTerminal() async {
        let base = TestSupervisorBase()
        let adapter = VoiceChatSupervisedSpeechRecognitionAdapter(base: base)
        var iterator = adapter.events.makeAsyncIterator()

        await base.emit(.transcript("partial"))
        await base.emit(.utterance("final"))
        await base.emit(.level(0.4))
        await base.emit(.state(.completed))

        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        let fourth = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(first, .transcript("partial"))
        XCTAssertEqual(second, .utterance("final"))
        XCTAssertEqual(third, .level(0.4))
        XCTAssertEqual(fourth, .finished)
        XCTAssertNil(end)
    }

    func testMapsTypedDegradationToOneFailureAndRejectsLateEvents() async {
        let base = TestSupervisorBase()
        let adapter = VoiceChatSupervisedSpeechRecognitionAdapter(base: base)
        var iterator = adapter.events.makeAsyncIterator()
        let failure = ASRFailure(code: .connectionLost)

        await base.emit(.state(.degraded(ASRSessionDegradation(
            failure: failure,
            disposition: .manualControl,
            recoveryAttemptCount: 1
        ))))
        await base.emit(.transcript("late"))

        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .failed(SpeechRecognitionFailure(code: .connectionLost)))
        XCTAssertNil(end)
    }

    func testStartMapsCoreDegradationAndUnknownFailures() async {
        let cases: [(TestSupervisorBase.StartOutcome, SpeechRecognitionFailure.Code)] = [
            (.core(ASRFailure(code: .timeout)), .timeout),
            (.degradation(ASRSessionDegradation(
                failure: ASRFailure(code: .networkUnavailable),
                disposition: .retryableFailure,
                recoveryAttemptCount: 1
            )), .networkUnavailable),
            (.unknown, .unknown)
        ]

        for (outcome, expectedCode) in cases {
            let base = TestSupervisorBase(startOutcome: outcome)
            let adapter = VoiceChatSupervisedSpeechRecognitionAdapter(base: base)
            do {
                try await adapter.start()
                XCTFail("Expected start failure")
            } catch {
                XCTAssertEqual(
                    error as? SpeechRecognitionFailure,
                    SpeechRecognitionFailure(code: expectedCode)
                )
            }
        }
    }

    func testForwardsLifecycleAndCancelsExactlyOnce() async throws {
        let base = TestSupervisorBase()
        let adapter = VoiceChatSupervisedSpeechRecognitionAdapter(base: base)

        try await adapter.start()
        await adapter.finish()
        await adapter.cancel()
        await adapter.cancel()

        let operations = await base.operations
        XCTAssertEqual(operations, [.start, .finish, .cancel])
    }
}

private actor TestSupervisorBase: VoiceChatASRSessionSupervisorBase {
    enum Operation: Equatable {
        case start
        case finish
        case cancel
    }

    enum StartOutcome: Sendable {
        case success
        case core(ASRFailure)
        case degradation(ASRSessionDegradation)
        case unknown
    }

    nonisolated let events: AsyncStream<ASRSessionSupervisorEvent>
    private let continuation: AsyncStream<ASRSessionSupervisorEvent>.Continuation
    private let startOutcome: StartOutcome
    private(set) var operations: [Operation] = []

    init(startOutcome: StartOutcome = .success) {
        let (events, continuation) = AsyncStream<ASRSessionSupervisorEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.startOutcome = startOutcome
    }

    func start() async throws {
        operations.append(.start)
        switch startOutcome {
        case .success:
            return
        case .core(let failure):
            throw failure
        case .degradation(let degradation):
            throw degradation
        case .unknown:
            throw TestSupervisorFailure.unknown
        }
    }

    func finish() async {
        operations.append(.finish)
    }

    func cancel() async {
        operations.append(.cancel)
    }

    func emit(_ event: ASRSessionSupervisorEvent) {
        continuation.yield(event)
    }
}

private enum TestSupervisorFailure: Error {
    case unknown
}
