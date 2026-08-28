import SingleGreenGlassesKit
import VoiceChatCore
import XCTest
@testable import SingleGreenDemo

@MainActor
final class VoiceActivatedASRAdapterTests: XCTestCase {
    func testMapsLifecyclePayloadsAndOneFinalizingEventExactlyOnce() async {
        let base = HostVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
        let collected = collect(adapter.events)

        await base.emit(.state(.arming))
        await base.emit(.state(.armed))
        await base.emit(.state(.armed))
        await base.emit(.state(.openingRecognizer))
        await base.emit(.state(.openingRecognizer))
        await base.emit(.state(.streaming))
        await base.emit(.transcript("你好"))
        await base.emit(.utterance("你好"))
        await base.emit(.level(0.4))
        await base.emit(.state(.draining(.silence)))
        await base.emit(.state(.finalizing(.silence)))
        await base.emit(.state(.finalizing(.silence)))
        await base.emit(.state(.finished))
        await base.emit(.state(.finished))
        await base.emit(.transcript("过期"))

        let values = await collected.value
        XCTAssertEqual(values, [
            .phase(.armed),
            .phase(.speechStarted),
            .transcript("你好"),
            .utterance("你好"),
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
            let base = HostVoiceActivatedASRSessionBase()
            let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
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

    func testDrainingImmediatelyMapsFinalizingAndLaterCoreFinalizingIsDeduplicated() async {
        let base = HostVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
        var iterator = adapter.events.makeAsyncIterator()

        await base.emit(.state(.draining(.manual)))
        let immediate = await iterator.next()

        XCTAssertEqual(immediate, .phase(.finalizing(.manual)))

        await base.emit(.state(.finalizing(.manual)))
        await base.emit(.state(.finished))

        let next = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(next, .finished)
        XCTAssertNil(end)
    }

    func testNoSpeechIsOneTerminalOutcomeAndRejectsFollowingFinishedOrPayloads() async {
        let base = HostVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
        let collected = collect(adapter.events)

        await base.emit(.state(.armed))
        await base.emit(.noSpeech)
        await base.emit(.state(.finished))
        await base.emit(.transcript("过期"))

        let values = await collected.value
        XCTAssertEqual(values, [.phase(.armed), .noSpeech])
    }

    func testMapsAllVADAndBackpressureFailureCodesAndRejectsLateEvents() async {
        let cases: [(ASRFailure.Code, SpeechRecognitionFailure.Code)] = [
            (.voiceActivityUnavailable, .voiceActivityUnavailable),
            (.voiceActivityProcessingFailed, .voiceActivityProcessingFailed),
            (.audioCaptureOverrun, .audioCaptureOverrun),
            (.uploadBackpressureExceeded, .uploadBackpressureExceeded)
        ]

        for (coreCode, portCode) in cases {
            let base = HostVoiceActivatedASRSessionBase()
            let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
            let collected = collect(adapter.events)

            await base.emit(.state(.failed(ASRFailure(code: coreCode))))
            await base.emit(.state(.finished))
            await base.emit(.level(1))

            let values = await collected.value
            XCTAssertEqual(values, [
                .failed(SpeechRecognitionFailure(code: portCode))
            ])
        }
    }

    func testCancelClosesBridgeForLateEventsAndForwardsCancellationOnce() async {
        let base = HostVoiceActivatedASRSessionBase()
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)
        let collected = collect(adapter.events)

        await adapter.cancel()
        await adapter.cancel()
        await base.emit(.state(.armed))
        await base.emit(.state(.finished))

        let values = await collected.value
        let cancelCount = await base.cancelCount
        XCTAssertEqual(values, [])
        XCTAssertEqual(cancelCount, 1)
    }

    func testArmAndFinishForwardToBaseAndMapTypedStartFailure() async {
        let failure = ASRFailure(code: .voiceActivityUnavailable)
        let base = HostVoiceActivatedASRSessionBase(armFailure: failure)
        let adapter = VoiceChatVoiceActivatedSpeechRecognitionSession(base: base)

        do {
            try await adapter.arm()
            XCTFail("Expected typed arm failure")
        } catch {
            XCTAssertEqual(
                error as? SpeechRecognitionFailure,
                SpeechRecognitionFailure(code: .voiceActivityUnavailable)
            )
        }

        await adapter.finish()
        let armCount = await base.armCount
        let finishCount = await base.finishCount
        XCTAssertEqual(armCount, 1)
        XCTAssertEqual(finishCount, 1)
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

private actor HostVoiceActivatedASRSessionBase: VoiceChatVoiceActivatedASRSessionBase {
    nonisolated let events: AsyncStream<VoiceActivatedASREvent>
    private let continuation: AsyncStream<VoiceActivatedASREvent>.Continuation
    private let armFailure: ASRFailure?
    private(set) var armCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init(armFailure: ASRFailure? = nil) {
        let (events, continuation) = AsyncStream<VoiceActivatedASREvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.armFailure = armFailure
    }

    func emit(_ event: VoiceActivatedASREvent) {
        continuation.yield(event)
    }

    func arm() async throws {
        armCount += 1
        if let armFailure { throw armFailure }
    }

    func finish() async {
        finishCount += 1
    }

    func cancel() async {
        cancelCount += 1
    }
}
