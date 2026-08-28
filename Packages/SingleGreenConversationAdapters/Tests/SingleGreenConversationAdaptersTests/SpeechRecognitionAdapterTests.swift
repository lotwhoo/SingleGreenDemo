import SingleGreenGlassesKit
import VoiceChatCore
import XCTest
@testable import SingleGreenConversationAdapters

final class SpeechRecognitionAdapterTests: XCTestCase {
    func testMapsPayloadsAndStopsAfterFinishedTerminal() async {
        let base = TestASRSessionBase()
        let adapter = VoiceChatSpeechRecognitionAdapter(base: base)
        let collected = collect(adapter.events)

        await base.emit(.state(.starting))
        await base.emit(.transcript("partial"))
        await base.emit(.utterance("final"))
        await base.emit(.level(0.25))
        await base.emit(.state(.finished))
        await base.emit(.transcript("late"))
        await base.emit(.state(.failed(.init(code: .unknown))))

        let values = await collected.value
        XCTAssertEqual(values, [
            .transcript("partial"),
            .utterance("final"),
            .level(0.25),
            .finished
        ])
    }

    func testMapsCoreErrorToOneTypedTerminalAndRejectsLateEvents() async {
        let base = TestASRSessionBase()
        let adapter = VoiceChatSpeechRecognitionAdapter(base: base)
        let collected = collect(adapter.events)

        await base.emit(.error(.transport(URLError(.notConnectedToInternet))))
        await base.emit(.state(.finished))

        let values = await collected.value
        XCTAssertEqual(values, [
            .failed(.init(
                code: .networkUnavailable,
                userSafeMessage: "网络或语音服务暂时不可用。"
            ))
        ])
    }

    func testStartMapsTypedFailureAndDoesNotForwardUnknownLocalizedDescription() async {
        let typedBase = TestASRSessionBase(startError: ASRFailure(code: .unauthorized))
        let typedAdapter = VoiceChatSpeechRecognitionAdapter(base: typedBase)

        do {
            try await typedAdapter.start()
            XCTFail("Expected typed start failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechRecognitionFailure,
                .init(code: .unauthorized)
            )
        }

        let unknownBase = TestASRSessionBase(startError: SensitiveFixtureError())
        let unknownAdapter = VoiceChatSpeechRecognitionAdapter(base: unknownBase)
        do {
            try await unknownAdapter.start()
            XCTFail("Expected unknown start failure")
        } catch let failure as SpeechRecognitionFailure {
            XCTAssertEqual(failure, .init(code: .unknown))
            XCTAssertNil(failure.userSafeMessage)
            XCTAssertFalse(String(describing: failure).contains(SensitiveFixtureError.sentinel))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartFinishAndCancelForwardToConfiguredBase() async throws {
        let base = TestASRSessionBase()
        let adapter = VoiceChatSpeechRecognitionAdapter(base: base)

        try await adapter.start()
        await adapter.finish()
        await adapter.cancel()

        let counts = await base.counts
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(counts.cancel, 1)
    }

    func testMapsEveryCoreFailureCode() {
        let cases: [(ASRFailure.Code, SpeechRecognitionFailure.Code)] = [
            (.unauthorized, .unauthorized),
            (.networkUnavailable, .networkUnavailable),
            (.timeout, .timeout),
            (.connectionLost, .connectionLost),
            (.audioInterrupted, .audioInterrupted),
            (.audioUnavailable, .audioUnavailable),
            (.voiceActivityUnavailable, .voiceActivityUnavailable),
            (.voiceActivityProcessingFailed, .voiceActivityProcessingFailed),
            (.audioCaptureOverrun, .audioCaptureOverrun),
            (.uploadBackpressureExceeded, .uploadBackpressureExceeded),
            (.protocolFailure, .protocolFailure),
            (.unknown, .unknown)
        ]

        for (core, port) in cases {
            XCTAssertEqual(
                VoiceChatSpeechRecognitionAdapter.failure(
                    forCoreFailure: ASRFailure(code: core)
                ).code,
                port
            )
        }
        XCTAssertEqual(
            VoiceChatSpeechRecognitionAdapter.failure(
                forAudioSystemEvent: .interruptionBegan
            )?.code,
            .audioInterrupted
        )
    }

    private func collect(
        _ stream: AsyncStream<SpeechRecognitionEvent>
    ) -> Task<[SpeechRecognitionEvent], Never> {
        Task {
            var values: [SpeechRecognitionEvent] = []
            for await value in stream { values.append(value) }
            return values
        }
    }
}

private actor TestASRSessionBase: VoiceChatASRSessionBase {
    struct Counts: Sendable {
        let start: Int
        let finish: Int
        let cancel: Int
    }

    nonisolated let events: AsyncStream<ASRSession.Event>
    private let continuation: AsyncStream<ASRSession.Event>.Continuation
    private let startError: (any Error)?
    private var startCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(startError: (any Error)? = nil) {
        let (events, continuation) = AsyncStream<ASRSession.Event>.makeStream()
        self.events = events
        self.continuation = continuation
        self.startError = startError
    }

    var counts: Counts {
        Counts(start: startCount, finish: finishCount, cancel: cancelCount)
    }

    func emit(_ event: ASRSession.Event) {
        continuation.yield(event)
    }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }
}

private struct SensitiveFixtureError: LocalizedError {
    static let sentinel = "SENSITIVE_PROVIDER_START_PAYLOAD"
    var errorDescription: String? { Self.sentinel }
}
