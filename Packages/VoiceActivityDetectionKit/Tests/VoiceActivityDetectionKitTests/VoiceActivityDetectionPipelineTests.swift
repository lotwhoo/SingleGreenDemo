import XCTest
import VADBenchmarkSupport
@testable import VoiceActivityDetectionKit

final class VoiceActivityDetectionPipelineTests: XCTestCase {
    func testScriptedDetectorErrorPropagatesWithoutSegmentation() async throws {
        let detector = ScriptedVoiceActivityDetector(script: [.failure(.injected)])
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy()
        )

        do {
            _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 0))
            XCTFail("Expected injected detector error")
        } catch {
            XCTAssertEqual(error as? ScriptedDetectorError, .injected)
        }
        let observedSequences = await detector.observedSequences
        XCTAssertEqual(observedSequences, [0])
    }

    func testPipelineResetResetsDetectorAndAllowsNewSequenceEpoch() async throws {
        let silence = try SyntheticPCMFixture.observation(isSpeech: false)
        let detector = ScriptedVoiceActivityDetector(script: [.success(silence), .success(silence)])
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy()
        )

        _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 100))
        await pipeline.reset()
        _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 1))

        let resetCount = await detector.resetCount
        let observedSequences = await detector.observedSequences
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(observedSequences, [100, 1])
    }

    func testPipelineRejectsDuplicateBeforeInvokingStatefulDetector() async throws {
        let silence = try SyntheticPCMFixture.observation(isSpeech: false)
        let detector = ScriptedVoiceActivityDetector(script: [.success(silence), .success(silence)])
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy()
        )

        _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 10))
        do {
            _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 10))
            XCTFail("Expected duplicate sequence rejection")
        } catch {
            XCTAssertEqual(
                error as? VADSegmentationError,
                .sequenceNotIncreasing(previous: 10, current: 10)
            )
        }
        _ = try await pipeline.process(SyntheticPCMFixture.frame(sequence: 11))

        let observedSequences = await detector.observedSequences
        XCTAssertEqual(observedSequences, [10, 11])
    }

    func testResetWhileDetectionIsSuspendedDiscardsPreResetWork() async throws {
        let speech = try SyntheticPCMFixture.observation(isSpeech: true)
        let detector = GatedVoiceActivityDetector(
            observations: [100: speech, 1: speech],
            gatedSequences: [100],
            fallbackObservation: speech,
            suspendNextReset: true
        )
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy(
                preRoll: 1,
                onsetWindow: 1,
                onsetRequired: 1
            )
        )
        let staleProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 100))
        }
        await detector.waitUntilObservedCount(1)

        let resetTask = Task {
            await pipeline.reset()
        }
        await detector.waitUntilResetCount(1)

        do {
            _ = try await staleProcess.value
            XCTFail("Expected pre-reset detection to be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let newProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 1))
        }
        await Task.yield()
        let observedDuringReset = await detector.observedSequences
        XCTAssertEqual(observedDuringReset, [100])

        await detector.releaseReset()
        await resetTask.value
        let newEvents = try await newProcess.value
        XCTAssertEqual(
            newEvents,
            [
                .segmentStarted(segmentID: 1),
                .frames(
                    segmentID: 1,
                    frames: [try SyntheticPCMFixture.frame(sequence: 1)]
                )
            ]
        )
        let observedSequences = await detector.observedSequences
        let resetCount = await detector.resetCount
        XCTAssertEqual(observedSequences, [100, 1])
        XCTAssertEqual(resetCount, 1)
    }

    func testConcurrentProcessCallsAreDetectedAndConsumedInFIFOOrder() async throws {
        let speech = try SyntheticPCMFixture.observation(isSpeech: true)
        let detector = GatedVoiceActivityDetector(
            observations: [10: speech, 11: speech],
            gatedSequences: [10],
            fallbackObservation: speech
        )
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy(
                preRoll: 1,
                onsetWindow: 1,
                onsetRequired: 1
            )
        )
        let firstProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 10))
        }
        await detector.waitUntilObservedCount(1)
        let secondProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 11))
        }

        await Task.yield()
        let observedWhileFirstSuspended = await detector.observedSequences
        XCTAssertEqual(observedWhileFirstSuspended, [10])

        await detector.release(sequence: 10)
        let firstEvents = try await firstProcess.value
        await detector.waitUntilObservedCount(2)
        let secondEvents = try await secondProcess.value

        XCTAssertEqual(
            firstEvents,
            [
                .segmentStarted(segmentID: 10),
                .frames(
                    segmentID: 10,
                    frames: [try SyntheticPCMFixture.frame(sequence: 10)]
                )
            ]
        )
        XCTAssertEqual(
            secondEvents,
            [
                .frames(
                    segmentID: 10,
                    frames: [try SyntheticPCMFixture.frame(sequence: 11)]
                )
            ]
        )
        let finalObservedSequences = await detector.observedSequences
        XCTAssertEqual(finalObservedSequences, [10, 11])
    }

    func testCancelledSuspendedDetectionCannotMutateLaterSegment() async throws {
        let speech = try SyntheticPCMFixture.observation(isSpeech: true)
        let detector = GatedVoiceActivityDetector(
            observations: [5: speech, 6: speech],
            gatedSequences: [5],
            fallbackObservation: speech
        )
        let pipeline = VoiceActivityDetectionPipeline(
            detector: detector,
            policy: try SyntheticPCMFixture.policy(
                preRoll: 1,
                onsetWindow: 1,
                onsetRequired: 1
            )
        )
        let cancelledProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 5))
        }
        await detector.waitUntilObservedCount(1)
        cancelledProcess.cancel()

        do {
            _ = try await cancelledProcess.value
            XCTFail("Expected cancelled detection to fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let laterProcess = Task {
            try await pipeline.process(SyntheticPCMFixture.frame(sequence: 6))
        }
        await detector.release(sequence: 5)
        let laterEvents = try await laterProcess.value

        XCTAssertEqual(
            laterEvents,
            [
                .segmentStarted(segmentID: 6),
                .frames(
                    segmentID: 6,
                    frames: [try SyntheticPCMFixture.frame(sequence: 6)]
                )
            ]
        )
    }

    func testEnergyDetectorExistsOnlyInBenchmarkSupportAndClassifiesSyntheticFrames() async throws {
        let detector = EnergyVoiceActivityDetector(speechMeanAbsoluteAmplitude: 800)
        let silence = try await detector.observation(
            for: SyntheticPCMFixture.frame(sequence: 0)
        )
        let signal = try await detector.observation(
            for: SyntheticPCMFixture.frame(sequence: 1, amplitude: 1_200)
        )

        XCTAssertFalse(silence.isSpeech)
        XCTAssertEqual(silence.speechProbability, 0)
        XCTAssertTrue(signal.isSpeech)
        XCTAssertEqual(signal.speechProbability, 1)
    }

    func testPublicValuesAndPipelineAreSendableUnderCompleteConcurrency() throws {
        func requireSendable<Value: Sendable>(_: Value) {}

        let frame = try SyntheticPCMFixture.frame(sequence: 0)
        let observation = try SyntheticPCMFixture.observation(isSpeech: false)
        let policy = try SyntheticPCMFixture.policy()
        let detector = ScriptedVoiceActivityDetector(script: [.success(observation)])
        let pipeline = VoiceActivityDetectionPipeline(detector: detector, policy: policy)

        requireSendable(frame)
        requireSendable(observation)
        requireSendable(policy)
        requireSendable(VADSegmenter(policy: policy))
        requireSendable(pipeline)
    }
}
