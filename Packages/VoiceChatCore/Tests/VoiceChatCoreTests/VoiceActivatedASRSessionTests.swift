import Foundation
import VoiceActivityDetectionKit
import XCTest
@testable import VoiceChatCore

final class VoiceActivatedASRSessionTests: XCTestCase {
    func testStandardPolicyUsesTwentyMillisecondProductThresholds() {
        let policy = VoiceActivatedASRPolicy.standard
        XCTAssertEqual(policy.segmentation.preRollFrameCount, 15)
        XCTAssertEqual(policy.segmentation.onsetWindowFrameCount, 5)
        XCTAssertEqual(policy.segmentation.onsetRequiredSpeechFrameCount, 3)
        XCTAssertEqual(policy.segmentation.endpointSilenceFrameCount, 40)
        XCTAssertEqual(policy.segmentation.maximumSegmentFrameCount, 1_000)
        XCTAssertEqual(policy.noSpeechFrameLimit, 750)
        XCTAssertEqual(policy.maximumPendingUploadFrameCount, 250)
        XCTAssertEqual(policy.uploadBatchFrameCount, 10)
    }

    func testPolicyRejectsUnboundedOrIncoherentQueueValues() throws {
        let segmentation = try makeSegmentation()
        XCTAssertThrowsError(try VoiceActivatedASRPolicy(
            segmentation: segmentation,
            noSpeechFrameLimit: 2,
            maximumPendingUploadFrameCount: 8,
            uploadBatchFrameCount: 2
        ))
        XCTAssertThrowsError(try VoiceActivatedASRPolicy(
            segmentation: segmentation,
            noSpeechFrameLimit: 10,
            maximumPendingUploadFrameCount: 2,
            uploadBatchFrameCount: 2
        ))
        XCTAssertThrowsError(try VoiceActivatedASRPolicy(
            segmentation: segmentation,
            noSpeechFrameLimit: 10,
            maximumPendingUploadFrameCount: 8,
            uploadBatchFrameCount: 9
        ))
    }

    func testSilenceTimesOutLocallyWithoutOpeningTransport() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(
            source: source,
            detector: detector,
            transport: transport,
            noSpeech: 5
        )
        let observation = collectEvents(from: session) { event in
            event == .state(.finished)
        }

        try await session.arm()
        for sequence in 0..<5 { await source.emit(try frame(UInt64(sequence))) }
        let events = await observation.value

        XCTAssertTrue(events.contains(.noSpeech))
        let state = await session.state
        XCTAssertEqual(state, .finished)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
        XCTAssertTrue(metrics.sentSequences.isEmpty)
        XCTAssertEqual(metrics.finishCount, 0)
    }

    func testOnsetDelaysConnectionAndUploadsPreRollAndEndpointFramesInStrictFIFO() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(
            speechBySequence: [0: false, 1: true, 2: true, 3: false, 4: false],
            defaultSpeech: false
        )
        let transport = FakeStreamingASRTransport(gateOpen: true, autoFinishEvent: false)
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.emit(try frame(0))
        await source.emit(try frame(1))
        await waitUntil { await transport.metrics().openCount == 0 }
        await source.emit(try frame(2))
        await transport.waitUntilOpenEntered()
        let openingState = await session.state
        XCTAssertEqual(openingState, .openingRecognizer)

        await source.emit(try frame(3))
        await source.emit(try frame(4))
        let delayedMetrics = await transport.metrics()
        XCTAssertTrue(delayedMetrics.sentSequences.isEmpty)
        await transport.releaseOpen()
        await waitUntil { await transport.metrics().finishCount == 1 }

        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 1)
        XCTAssertEqual(metrics.sentSequences, [0, 1, 2, 3, 4])
        XCTAssertEqual(metrics.operations.last, "finish")
        let finalizingState = await session.state
        XCTAssertEqual(finalizingState, .finalizing(.silence))

        await transport.emit(.finished)
        await waitUntil { await session.state == .finished }
    }

    func testManualFinishBeforeOnsetNeverOpensNetwork() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.emit(try frame(0))
        await session.finish()

        let state = await session.state
        XCTAssertEqual(state, .finished)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
        XCTAssertEqual(metrics.finishCount, 0)
        XCTAssertTrue(metrics.sentSequences.isEmpty)
    }

    func testManualFinishAfterOnsetFlushesRemainderBeforeFinalFrame() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(autoFinishEvent: false)
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await source.emit(try frame(3))
        await session.finish()
        await waitUntil { await transport.metrics().finishCount == 1 }

        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.sentSequences, [0, 1, 2, 3])
        XCTAssertEqual(metrics.operations.last, "finish")
        let finalizingState = await session.state
        XCTAssertEqual(finalizingState, .finalizing(.manual))
    }

    func testMaximumDurationEndpointFinalizesExactlyOnce() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(autoFinishEvent: false)
        let policy = try makePolicy(
            preRoll: 1,
            onsetWindow: 1,
            onsetRequired: 1,
            endpointSilence: 4,
            maximumSegment: 3,
            pending: 8,
            batch: 2
        )
        let session = VoiceActivatedASRSession(
            frameSource: source,
            detector: detector,
            transport: transport,
            policy: policy
        )

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await transport.metrics().finishCount == 1 }

        let finalizingState = await session.state
        XCTAssertEqual(finalizingState, .finalizing(.maximumDuration))
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.sentSequences, [0, 1, 2])
        XCTAssertEqual(metrics.finishCount, 1)
    }

    func testBoundedQueueOverflowFailsWithoutOpeningTransport() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false, gatedSequences: [0])
        let transport = FakeStreamingASRTransport()
        let policy = try makePolicy(pending: 3, batch: 1)
        let session = VoiceActivatedASRSession(
            frameSource: source,
            detector: detector,
            transport: transport,
            policy: policy
        )

        try await session.arm()
        await source.emit(try frame(0))
        await detector.waitUntilObserved(sequence: 0)
        for sequence in 1...4 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected backpressure failure")
        }
        XCTAssertEqual(failure.code, .uploadBackpressureExceeded)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
    }

    func testDetectorFailureIsCoarseAndNeverOpensTransport() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false, failingSequences: [0])
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.emit(try frame(0))
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected detector failure")
        }
        XCTAssertEqual(failure.code, .voiceActivityProcessingFailed)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
    }

    func testSendFailureTerminatesAndDoesNotRetryOrDuplicateFrames() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(sendFailureAtCall: 1)
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected send failure")
        }
        XCTAssertEqual(failure.code, .connectionLost)
        await waitUntil { await transport.metrics().cancelCount == 1 }
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.sendCallCount, 1)
        XCTAssertTrue(metrics.sentSequences.isEmpty)
        XCTAssertEqual(metrics.cancelCount, 1)
    }

    func testFinalSendFailureBecomesTerminalFailure() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(finishFailure: true)
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await session.finish()
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected final-send failure")
        }
        XCTAssertEqual(failure.code, .connectionLost)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.finishCount, 1)
    }

    func testTransportEventStreamClosureWithoutTerminalEventFailsOnceAndCancels() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(autoFinishEvent: false)
        let session = try makeSession(source: source, detector: detector, transport: transport)
        let terminalEvents = collectEvents(from: session) { event in
            if case .state(.failed) = event { return true }
            return false
        }

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await transport.endCurrentEventStream()
        let events = await terminalEvents.value
        await waitUntil { await transport.metrics().cancelCount == 1 }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected event-stream closure to fail the active recognition")
        }
        XCTAssertEqual(failure.code, .connectionLost)
        XCTAssertEqual(events.filter { event in
            if case .state(.failed) = event { return true }
            return false
        }.count, 1)
        let metricsAfterFailure = await transport.metrics()
        XCTAssertEqual(metricsAfterFailure.cancelCount, 1)

        await transport.endEventStream(at: 0)
        await Task.yield()
        let metricsAfterRepeatedClosure = await transport.metrics()
        XCTAssertEqual(metricsAfterRepeatedClosure.cancelCount, 1)
    }

    func testStaleEventStreamClosureCannotFailRearmedGeneration() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(
            autoFinishEvent: false,
            finishEventStreamOnCancel: false
        )
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await session.cancel()

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await transport.endEventStream(at: 0)
        for _ in 0..<100 { await Task.yield() }

        let stateAfterStaleClosure = await session.state
        let metricsAfterStaleClosure = await transport.metrics()
        XCTAssertEqual(stateAfterStaleClosure, .streaming)
        XCTAssertEqual(metricsAfterStaleClosure.cancelCount, 1)
        await session.cancel()
    }

    func testDelayedSendAppliesBackpressureAndPreservesEveryAcceptedFrameInFIFO() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(autoFinishEvent: false, gateFirstSend: true)
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await transport.waitUntilFirstSendEntered()
        for sequence in 3..<6 { await source.emit(try frame(UInt64(sequence))) }
        let finish = Task { await session.finish() }
        await Task.yield()

        let blockedMetrics = await transport.metrics()
        XCTAssertEqual(blockedMetrics.sendCallCount, 1)
        await transport.releaseFirstSend()
        await finish.value

        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.sentSequences, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(Set(metrics.sentSequences).count, metrics.sentSequences.count)
        XCTAssertEqual(metrics.operations.last, "finish")
    }

    func testAutomaticEndpointDrainsThroughEndpointAndDiscardsLaterQueuedCapture() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(
            speechBySequence: [0: true, 1: false, 2: false, 3: true],
            defaultSpeech: false
        )
        let transport = FakeStreamingASRTransport(autoFinishEvent: false, gateFirstSend: true)
        let policy = try makePolicy(
            preRoll: 1,
            onsetWindow: 1,
            onsetRequired: 1,
            endpointSilence: 2,
            maximumSegment: 20,
            pending: 8,
            batch: 1
        )
        let session = VoiceActivatedASRSession(
            frameSource: source,
            detector: detector,
            transport: transport,
            policy: policy
        )

        try await session.arm()
        await source.emit(try frame(0))
        await transport.waitUntilFirstSendEntered()
        for sequence in 1...3 { await source.emit(try frame(UInt64(sequence))) }
        await transport.releaseFirstSend()
        await waitUntil { await transport.metrics().finishCount == 1 }

        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.sentSequences, [0, 1, 2])
        XCTAssertFalse(metrics.sentSequences.contains(3))
        let state = await session.state
        XCTAssertEqual(state, .finalizing(.silence))
    }

    func testLateEventDuringHardCancelCannotCrossIntoRearmedGeneration() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(gateCancel: true)
        let session = try makeSession(source: source, detector: detector, transport: transport)
        let transcripts = EventRecorder()
        let observation = Task {
            for await event in session.events {
                if case .transcript(let text) = event { await transcripts.append(text) }
            }
        }

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        let cancel = Task { await session.cancel() }
        await transport.waitUntilCancelEntered()
        await transport.emit(.transcript("stale"))
        await transport.releaseCancel()
        await cancel.value

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await waitUntil { await session.state == .streaming }
        await transport.emit(.transcript("current"))
        await waitUntil { await transcripts.values().contains("current") }

        let recordedTranscripts = await transcripts.values()
        XCTAssertEqual(recordedTranscripts, ["current"])
        observation.cancel()
    }

    func testCancelDuringDelayedOpenRejectsLateTransportEvents() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: true)
        let transport = FakeStreamingASRTransport(gateOpen: true)
        let session = try makeSession(source: source, detector: detector, transport: transport)
        let transcripts = EventRecorder()
        let observation = Task {
            for await event in session.events {
                if case .transcript(let text) = event { await transcripts.append(text) }
            }
        }

        try await session.arm()
        for sequence in 0..<3 { await source.emit(try frame(UInt64(sequence))) }
        await transport.waitUntilOpenEntered()
        let cancel = Task { await session.cancel() }
        await transport.releaseOpen()
        await cancel.value
        await transport.emit(.transcript("late transcript"))
        await Task.yield()

        let state = await session.state
        let recordedTranscripts = await transcripts.values()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(recordedTranscripts.isEmpty)
        observation.cancel()
    }

    func testUnexpectedFrameStreamEndFailsWithStaticAudioCode() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.endUnexpectedly()
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected source termination failure")
        }
        XCTAssertEqual(failure.code, .audioUnavailable)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
    }

    func testCaptureBufferOverflowUsesCoarseLocalFailureAndNoNetwork() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.fail(PCMFrameSourceFailure.bufferOverflow)
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected source buffer failure")
        }
        XCTAssertEqual(failure.code, .audioCaptureOverrun)
        XCTAssertFalse(failure.userSafeMessage?.isEmpty ?? true)
        let metrics = await transport.metrics()
        XCTAssertEqual(metrics.openCount, 0)
    }

    func testCaptureInterruptionPreservesTypedFailureAndNeverOpensNetwork() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(source: source, detector: detector, transport: transport)

        try await session.arm()
        await source.fail(PCMFrameSourceFailure.audioSystemEvent(.interruptionBegan))
        await waitUntil {
            if case .failed = await session.state { return true }
            return false
        }

        guard case .failed(let failure) = await session.state else {
            return XCTFail("Expected capture interruption failure")
        }
        let metrics = await transport.metrics()
        XCTAssertEqual(failure.code, .audioInterrupted)
        XCTAssertEqual(metrics.openCount, 0)
    }

    func testConcurrentArmsAfterGatedTerminalCleanupAdmitExactlyOneRun() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let session = try makeSession(
            source: source,
            detector: detector,
            transport: transport
        )

        try await session.arm()
        await source.suspendNextStop()
        await source.fail(PCMFrameSourceFailure.bufferOverflow)
        await source.waitUntilStopIsSuspended()

        let firstAttempt = Task { await armOutcome(session) }
        let secondAttempt = Task { await armOutcome(session) }
        await source.releaseSuspendedStop()
        let outcomes = await [firstAttempt.value, secondAttempt.value]

        XCTAssertEqual(outcomes.filter { $0 == .started }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .busy }.count, 1)
        let startCount = await source.startCount
        XCTAssertEqual(startCount, 2)
        await session.cancel()
    }

    func testArmWaiterCannotClearNewerCleanupOrStartBeforeItCompletes() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        let cleanupGate = CleanupWaitGate()
        let session = VoiceActivatedASRSession(
            frameSource: source,
            detector: detector,
            transport: transport,
            policy: try makePolicy(),
            cleanupWaitHook: { cleanupID, phase in
                await cleanupGate.observe(cleanupID: cleanupID, phase: phase)
            }
        )

        try await session.arm()
        await source.suspendNextStop()
        await source.fail(PCMFrameSourceFailure.bufferOverflow)
        await source.waitUntilStopIsSuspended()

        let firstArm = Task { await armOutcome(session) }
        let secondArm = Task { await armOutcome(session) }
        await cleanupGate.waitUntilTwoWaitersObserveFirstCleanup()
        await source.releaseSuspendedStop()
        await cleanupGate.waitUntilSecondCompletionIsSuspended()
        await waitUntil { await source.startCount == 2 }

        await source.suspendNextStop()
        let cancelFirstArm = Task { await session.cancel() }
        await source.waitUntilStopIsSuspended()
        await cleanupGate.releaseSecondCompletion()
        await waitUntil {
            if await cleanupGate.hasObservedNewerCleanup { return true }
            return await source.startCount > 2
        }

        let observedNewerCleanup = await cleanupGate.hasObservedNewerCleanup
        let startsWhileNewerCleanupIsBlocked = await source.startCount
        let maximumActiveRunsBeforeRelease = await source.maximumActiveRunCount
        XCTAssertTrue(observedNewerCleanup)
        XCTAssertEqual(startsWhileNewerCleanupIsBlocked, 2)
        XCTAssertEqual(maximumActiveRunsBeforeRelease, 1)

        await source.releaseSuspendedStop()
        await cancelFirstArm.value
        let outcomes = await [firstArm.value, secondArm.value]
        let finalStartCount = await source.startCount
        let finalActiveRunCount = await source.activeRunCount
        let finalMaximumActiveRunCount = await source.maximumActiveRunCount
        XCTAssertEqual(outcomes, [.started, .started])
        XCTAssertEqual(finalStartCount, 3)
        XCTAssertEqual(finalActiveRunCount, 1)
        XCTAssertEqual(finalMaximumActiveRunCount, 1)
        await session.cancel()
    }

    func testSessionDeallocatesWhileInjectedStreamsRemainOpen() async throws {
        let source = FakePCMFrameSource()
        let detector = FakeVoiceActivityDetector(defaultSpeech: false)
        let transport = FakeStreamingASRTransport()
        weak var weakSession: VoiceActivatedASRSession?

        do {
            let session = try makeSession(source: source, detector: detector, transport: transport)
            weakSession = session
            try await session.arm()
        }

        for _ in 0..<100 where weakSession != nil { await Task.yield() }
        XCTAssertNil(weakSession)
    }

    func testLegacyASRSessionStillUsesOriginalClientLifecycle() async throws {
        let client = LegacyCompatibilityClient()
        let session = ASRSession(client: client)

        try await session.startStream()
        session.pushAudio(Data([1, 2, 3]))
        await waitUntil { await client.pushCount == 1 }
        await session.finish()

        let counts = await client.counts()
        XCTAssertEqual(counts.start, 1)
        XCTAssertEqual(counts.push, 1)
        XCTAssertEqual(counts.finish, 1)
    }
}

private func makeSegmentation(
    preRoll: Int = 3,
    onsetWindow: Int = 3,
    onsetRequired: Int = 2,
    endpointSilence: Int = 2,
    maximumSegment: Int = 20
) throws -> VADSegmentationPolicy {
    try VADSegmentationPolicy(
        preRollFrameCount: preRoll,
        onsetWindowFrameCount: onsetWindow,
        onsetRequiredSpeechFrameCount: onsetRequired,
        endpointSilenceFrameCount: endpointSilence,
        maximumSegmentFrameCount: maximumSegment
    )
}

private func makePolicy(
    preRoll: Int = 3,
    onsetWindow: Int = 3,
    onsetRequired: Int = 2,
    endpointSilence: Int = 2,
    maximumSegment: Int = 20,
    noSpeech: Int = 10,
    pending: Int = 12,
    batch: Int = 2
) throws -> VoiceActivatedASRPolicy {
    try VoiceActivatedASRPolicy(
        segmentation: makeSegmentation(
            preRoll: preRoll,
            onsetWindow: onsetWindow,
            onsetRequired: onsetRequired,
            endpointSilence: endpointSilence,
            maximumSegment: maximumSegment
        ),
        noSpeechFrameLimit: noSpeech,
        maximumPendingUploadFrameCount: pending,
        uploadBatchFrameCount: batch
    )
}

private func makeSession(
    source: FakePCMFrameSource,
    detector: FakeVoiceActivityDetector,
    transport: FakeStreamingASRTransport,
    noSpeech: Int = 10
) throws -> VoiceActivatedASRSession {
    VoiceActivatedASRSession(
        frameSource: source,
        detector: detector,
        transport: transport,
        policy: try makePolicy(noSpeech: noSpeech)
    )
}

private func frame(_ sequence: UInt64) throws -> VADPCMFrame {
    try VADPCMFrame(
        sequence: sequence,
        samples: Array(repeating: Int16(sequence), count: VADPCMFrame.sampleCount)
    )
}

private func waitUntil(
    maxYields: Int = 20_000,
    _ predicate: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<maxYields {
        if await predicate() { return }
        await Task.yield()
    }
}

private func collectEvents(
    from session: VoiceActivatedASRSession,
    until predicate: @escaping @Sendable (VoiceActivatedASREvent) -> Bool
) -> Task<[VoiceActivatedASREvent], Never> {
    Task {
        var events: [VoiceActivatedASREvent] = []
        for await event in session.events {
            events.append(event)
            if predicate(event) { return events }
        }
        return events
    }
}

private enum ArmOutcome: Equatable, Sendable {
    case started
    case busy
    case unexpectedFailure
}

private func armOutcome(_ session: VoiceActivatedASRSession) async -> ArmOutcome {
    do {
        try await session.arm()
        return .started
    } catch VoiceActivatedASRSessionError.busy {
        return .busy
    } catch {
        return .unexpectedFailure
    }
}

private actor CleanupWaitGate {
    private var firstCleanupID: UInt64?
    private var firstCleanupWillAwaitCount = 0
    private var firstCleanupDidAwaitCount = 0
    private var observedNewerCleanup = false
    private var releaseSecondCompletionImmediately = false
    private var secondCompletionContinuation: CheckedContinuation<Void, Never>?
    private var twoWaiterContinuations: [CheckedContinuation<Void, Never>] = []
    private var secondCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    var hasObservedNewerCleanup: Bool { observedNewerCleanup }

    func observe(
        cleanupID: UInt64,
        phase: VoiceActivatedASRCleanupWaitPhase
    ) async {
        if firstCleanupID == nil { firstCleanupID = cleanupID }
        guard cleanupID == firstCleanupID else {
            if phase == .willAwait {
                observedNewerCleanup = true
            }
            return
        }

        switch phase {
        case .willAwait:
            firstCleanupWillAwaitCount += 1
            if firstCleanupWillAwaitCount >= 2 {
                twoWaiterContinuations.forEach { $0.resume() }
                twoWaiterContinuations.removeAll()
            }
        case .didAwait:
            firstCleanupDidAwaitCount += 1
            guard firstCleanupDidAwaitCount == 2 else { return }
            secondCompletionWaiters.forEach { $0.resume() }
            secondCompletionWaiters.removeAll()
            guard !releaseSecondCompletionImmediately else { return }
            await withCheckedContinuation { continuation in
                secondCompletionContinuation = continuation
            }
        }
    }

    func waitUntilTwoWaitersObserveFirstCleanup() async {
        guard firstCleanupWillAwaitCount < 2 else { return }
        await withCheckedContinuation { continuation in
            twoWaiterContinuations.append(continuation)
        }
    }

    func waitUntilSecondCompletionIsSuspended() async {
        guard firstCleanupDidAwaitCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondCompletionWaiters.append(continuation)
        }
    }

    func releaseSecondCompletion() {
        releaseSecondCompletionImmediately = true
        secondCompletionContinuation?.resume()
        secondCompletionContinuation = nil
    }

}

private actor FakePCMFrameSource: PCMFrameSource {
    private var frameContinuation: AsyncThrowingStream<VADPCMFrame, any Error>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var activeRunCount = 0
    private(set) var maximumActiveRunCount = 0
    private var shouldSuspendNextStop = false
    private var stopIsSuspended = false
    private var suspendedStopContinuation: CheckedContinuation<Void, Never>?
    private var stopSuspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func start() async throws -> PCMFrameSourceStreams {
        startCount += 1
        activeRunCount += 1
        maximumActiveRunCount = max(maximumActiveRunCount, activeRunCount)
        let (frames, frameContinuation) = AsyncThrowingStream<VADPCMFrame, any Error>.makeStream()
        let (levels, levelContinuation) = AsyncStream<Float>.makeStream()
        self.frameContinuation = frameContinuation
        self.levelContinuation = levelContinuation
        return PCMFrameSourceStreams(frames: frames, levels: levels)
    }

    func stop() async {
        stopCount += 1
        if activeRunCount > 0 { activeRunCount -= 1 }
        frameContinuation?.finish()
        levelContinuation?.finish()
        frameContinuation = nil
        levelContinuation = nil
        guard shouldSuspendNextStop else { return }
        shouldSuspendNextStop = false
        stopIsSuspended = true
        stopSuspensionWaiters.forEach { $0.resume() }
        stopSuspensionWaiters.removeAll()
        await withCheckedContinuation { continuation in
            suspendedStopContinuation = continuation
        }
        stopIsSuspended = false
    }

    func suspendNextStop() {
        shouldSuspendNextStop = true
    }

    func waitUntilStopIsSuspended() async {
        guard !stopIsSuspended else { return }
        await withCheckedContinuation { continuation in
            stopSuspensionWaiters.append(continuation)
        }
    }

    func releaseSuspendedStop() {
        suspendedStopContinuation?.resume()
        suspendedStopContinuation = nil
    }

    func emit(_ frame: VADPCMFrame) {
        frameContinuation?.yield(frame)
    }

    func emit(level: Float) {
        levelContinuation?.yield(level)
    }

    func endUnexpectedly() {
        frameContinuation?.finish()
    }

    func fail(_ error: any Error) {
        frameContinuation?.finish(throwing: error)
    }
}

private enum FakeDetectorFailure: Error, Sendable {
    case injected
}

private actor FakeVoiceActivityDetector: VoiceActivityDetecting {
    private let speechBySequence: [UInt64: Bool]
    private let defaultSpeech: Bool
    private let failingSequences: Set<UInt64>
    private var gatedSequences: Set<UInt64>
    private var gates: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var observedSequences: Set<UInt64> = []
    private var waiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]

    init(
        speechBySequence: [UInt64: Bool] = [:],
        defaultSpeech: Bool,
        gatedSequences: Set<UInt64> = [],
        failingSequences: Set<UInt64> = []
    ) {
        self.speechBySequence = speechBySequence
        self.defaultSpeech = defaultSpeech
        self.gatedSequences = gatedSequences
        self.failingSequences = failingSequences
    }

    func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        observedSequences.insert(frame.sequence)
        waiters.removeValue(forKey: frame.sequence)?.forEach { $0.resume() }
        if gatedSequences.remove(frame.sequence) != nil {
            await withCheckedContinuation { continuation in
                gates[frame.sequence] = continuation
            }
        }
        if failingSequences.contains(frame.sequence) { throw FakeDetectorFailure.injected }
        let isSpeech = speechBySequence[frame.sequence] ?? defaultSpeech
        return try VoiceActivityObservation(
            speechProbability: isSpeech ? 1 : 0,
            isSpeech: isSpeech
        )
    }

    func reset() async {
        let pending = gates.values
        gates.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilObserved(sequence: UInt64) async {
        guard !observedSequences.contains(sequence) else { return }
        await withCheckedContinuation { continuation in
            waiters[sequence, default: []].append(continuation)
        }
    }
}

private actor FakeStreamingASRTransport: StreamingASRTransport {
    struct Metrics: Sendable {
        let openCount: Int
        let sendCallCount: Int
        let finishCount: Int
        let cancelCount: Int
        let sentSequences: [UInt64]
        let operations: [String]
    }

    private var continuation: AsyncStream<StreamingASRTransportEvent>.Continuation?
    private let gateOpen: Bool
    private let autoFinishEvent: Bool
    private let sendFailureAtCall: Int?
    private let finishFailure: Bool
    private let gateFirstSend: Bool
    private let gateCancel: Bool
    private let finishEventStreamOnCancel: Bool
    private var openRelease: CheckedContinuation<Void, Never>?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSendRelease: CheckedContinuation<Void, Never>?
    private var firstSendWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelRelease: CheckedContinuation<Void, Never>?
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var openCount = 0
    private var sendCallCount = 0
    private var finishCount = 0
    private var cancelCount = 0
    private var sentSequences: [UInt64] = []
    private var operations: [String] = []
    private var eventContinuations: [AsyncStream<StreamingASRTransportEvent>.Continuation] = []

    init(
        gateOpen: Bool = false,
        autoFinishEvent: Bool = true,
        sendFailureAtCall: Int? = nil,
        finishFailure: Bool = false,
        gateFirstSend: Bool = false,
        gateCancel: Bool = false,
        finishEventStreamOnCancel: Bool = true
    ) {
        self.gateOpen = gateOpen
        self.autoFinishEvent = autoFinishEvent
        self.sendFailureAtCall = sendFailureAtCall
        self.finishFailure = finishFailure
        self.gateFirstSend = gateFirstSend
        self.gateCancel = gateCancel
        self.finishEventStreamOnCancel = finishEventStreamOnCancel
    }

    func openStream() async throws -> AsyncStream<StreamingASRTransportEvent> {
        continuation?.finish()
        let (events, continuation) = AsyncStream<StreamingASRTransportEvent>.makeStream()
        self.continuation = continuation
        eventContinuations.append(continuation)
        openCount += 1
        operations.append("open")
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if gateOpen {
            await withCheckedContinuation { continuation in
                openRelease = continuation
            }
            openRelease = nil
        }
        return events
    }

    func send(frames: [VADPCMFrame]) async throws {
        sendCallCount += 1
        operations.append("send:\(frames.map(\.sequence))")
        if gateFirstSend, sendCallCount == 1 {
            let waiters = firstSendWaiters
            firstSendWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstSendRelease = continuation
            }
            firstSendRelease = nil
        }
        if sendFailureAtCall == sendCallCount {
            throw ASRFailure(code: .connectionLost)
        }
        sentSequences.append(contentsOf: frames.map(\.sequence))
    }

    func finishStream() async throws {
        finishCount += 1
        operations.append("finish")
        if finishFailure { throw ASRFailure(code: .connectionLost) }
        if autoFinishEvent { continuation?.yield(.finished) }
    }

    func cancelStream() async {
        cancelCount += 1
        operations.append("cancel")
        openRelease?.resume()
        openRelease = nil
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if gateCancel {
            await withCheckedContinuation { continuation in
                cancelRelease = continuation
            }
            cancelRelease = nil
        }
        if finishEventStreamOnCancel { continuation?.finish() }
        continuation = nil
    }

    func emit(_ event: StreamingASRTransportEvent) {
        continuation?.yield(event)
    }

    func endCurrentEventStream() {
        continuation?.finish()
    }

    func endEventStream(at index: Int) {
        eventContinuations[index].finish()
    }

    func waitUntilOpenEntered() async {
        guard openCount == 0 else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func releaseOpen() {
        openRelease?.resume()
        openRelease = nil
    }

    func waitUntilFirstSendEntered() async {
        guard sendCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstSendWaiters.append(continuation)
        }
    }

    func releaseFirstSend() {
        firstSendRelease?.resume()
        firstSendRelease = nil
    }

    func waitUntilCancelEntered() async {
        guard cancelCount == 0 else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    func releaseCancel() {
        cancelRelease?.resume()
        cancelRelease = nil
    }

    func metrics() -> Metrics {
        Metrics(
            openCount: openCount,
            sendCallCount: sendCallCount,
            finishCount: finishCount,
            cancelCount: cancelCount,
            sentSequences: sentSequences,
            operations: operations
        )
    }
}

private actor EventRecorder {
    private var recorded: [String] = []
    func append(_ value: String) { recorded.append(value) }
    func values() -> [String] { recorded }
}

private actor LegacyCompatibilityClient: ASRSessionClient {
    nonisolated let events: AsyncStream<ASRClient.Event>
    private let continuation: AsyncStream<ASRClient.Event>.Continuation
    private(set) var startCount = 0
    private(set) var pushCount = 0
    private(set) var finishCount = 0

    init() {
        let (events, continuation) = AsyncStream<ASRClient.Event>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func start() async throws {
        startCount += 1
        continuation.yield(.state(.connecting))
        continuation.yield(.state(.streaming))
    }

    func pushAudio(_ data: Data) async { pushCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { continuation.yield(.state(.idle)) }

    func counts() -> (start: Int, push: Int, finish: Int) {
        (startCount, pushCount, finishCount)
    }
}
