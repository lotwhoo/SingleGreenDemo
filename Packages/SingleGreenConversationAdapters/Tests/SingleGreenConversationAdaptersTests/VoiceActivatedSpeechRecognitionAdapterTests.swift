import SingleGreenGlassesKit
import VoiceChatCore
import XCTest
@testable import SingleGreenConversationAdapters

final class VoiceActivatedSpeechRecognitionAdapterTests: XCTestCase {
    func testMapsLifecyclePayloadsAndDeduplicatesEveryPhase() async {
        let base = TestVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
        let collected = collect(adapter.events)

        await base.emit(.state(.arming))
        await base.emit(.state(.armed))
        await base.emit(.state(.armed))
        await base.emit(.state(.openingRecognizer))
        await base.emit(.state(.openingRecognizer))
        await base.emit(.state(.streaming))
        await base.emit(.transcript("partial"))
        await base.emit(.utterance("final"))
        await base.emit(.level(0.4))
        await base.emit(.state(.draining(.silence)))
        await base.emit(.state(.finalizing(.silence)))
        await base.emit(.state(.finalizing(.silence)))
        await base.emit(.state(.finished))

        let values = await collected.value
        XCTAssertEqual(values, [
            .phase(.armed),
            .phase(.speechStarted),
            .transcript("partial"),
            .utterance("final"),
            .level(0.4),
            .phase(.finalizing(.silence)),
            .finished
        ])
    }

    func testMapsEveryEndpointReason() async {
        let cases: [(VoiceActivatedEndpointReason, VoiceEndpointReason)] = [
            (.silence, .silence),
            (.maximumDuration, .maximumDuration),
            (.manual, .manual)
        ]

        for (core, port) in cases {
            let base = TestVoiceActivatedASRSessionBase()
            let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
            let collected = collect(adapter.events)
            await base.emit(.state(.finalizing(core)))
            await base.emit(.state(.finished))
            let values = await collected.value
            XCTAssertEqual(values, [
                .phase(.finalizing(port)),
                .finished
            ])
        }
    }

    func testDrainingMapsFinalizingImmediatelyAndCoreFinalizingIsDeduplicated() async {
        let base = TestVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
        var iterator = adapter.events.makeAsyncIterator()

        await base.emit(.state(.draining(.manual)))
        let immediate = await iterator.next()
        XCTAssertEqual(immediate, .phase(.finalizing(.manual)))
        await base.emit(.state(.finalizing(.manual)))
        await base.emit(.state(.finished))
        let terminal = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(terminal, .finished)
        XCTAssertNil(end)
    }

    func testNoSpeechIsTerminalAndRejectsFollowingFinishedAndPayloads() async {
        let base = TestVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
        let collected = collect(adapter.events)

        await base.emit(.state(.armed))
        await base.emit(.noSpeech)
        await base.emit(.state(.finished))
        await base.emit(.transcript("late"))

        let values = await collected.value
        XCTAssertEqual(values, [.phase(.armed), .noSpeech])
    }

    func testFailureIsTerminalAndRejectsLateEvents() async {
        let cases: [(ASRFailure.Code, SpeechRecognitionFailure.Code)] = [
            (.voiceActivityUnavailable, .voiceActivityUnavailable),
            (.voiceActivityProcessingFailed, .voiceActivityProcessingFailed),
            (.audioCaptureOverrun, .audioCaptureOverrun),
            (.uploadBackpressureExceeded, .uploadBackpressureExceeded)
        ]

        for (coreCode, portCode) in cases {
            let base = TestVoiceActivatedASRSessionBase()
            let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
            let collected = collect(adapter.events)
            await base.emit(.state(.failed(.init(code: coreCode))))
            await base.emit(.state(.finished))
            await base.emit(.level(1))
            let values = await collected.value
            XCTAssertEqual(values, [
                .failed(.init(code: portCode))
            ])
        }
    }

    func testCancelClosesBridgeForLateEventsAndCancelsBaseExactlyOnce() async {
        let base = TestVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)
        let collected = collect(adapter.events)

        await adapter.cancel()
        await adapter.cancel()
        await base.emit(.state(.armed))
        await base.emit(.state(.finished))

        let values = await collected.value
        let counts = await base.counts
        XCTAssertEqual(values, [])
        XCTAssertEqual(counts.cancel, 1)
    }

    func testArmAndFinishForwardAndArmMapsTypedFailure() async {
        let base = TestVoiceActivatedASRSessionBase(
            armError: ASRFailure(code: .voiceActivityUnavailable)
        )
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionAdapter(base: base)

        do {
            try await adapter.arm()
            XCTFail("Expected typed arm failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechRecognitionFailure,
                .init(code: .voiceActivityUnavailable)
            )
        }

        await adapter.finish()
        let counts = await base.counts
        XCTAssertEqual(counts.arm, 1)
        XCTAssertEqual(counts.finish, 1)
        await adapter.cancel()
    }

    private func collect(
        _ stream: AsyncStream<VoiceActivatedRecognitionEvent>
    ) -> Task<[VoiceActivatedRecognitionEvent], Never> {
        Task {
            var values: [VoiceActivatedRecognitionEvent] = []
            for await value in stream { values.append(value) }
            return values
        }
    }
}

private actor TestVoiceActivatedASRSessionBase: VoiceChatVoiceActivatedASRSessionBase {
    struct Counts: Sendable {
        let arm: Int
        let finish: Int
        let cancel: Int
    }

    nonisolated let events: AsyncStream<VoiceActivatedASREvent>
    private let continuation: AsyncStream<VoiceActivatedASREvent>.Continuation
    private let armError: (any Error)?
    private var armCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(armError: (any Error)? = nil) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.armError = armError
    }

    var counts: Counts {
        Counts(arm: armCount, finish: finishCount, cancel: cancelCount)
    }

    func emit(_ event: VoiceActivatedASREvent) {
        continuation.yield(event)
    }

    func arm() async throws {
        armCount += 1
        if let armError { throw armError }
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }
}
