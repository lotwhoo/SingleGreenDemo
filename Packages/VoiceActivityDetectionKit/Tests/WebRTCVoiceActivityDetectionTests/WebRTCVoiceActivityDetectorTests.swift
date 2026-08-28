import CWebRTCVAD
import CWebRTCVADTestSupport
import Dispatch
import Foundation
import VoiceActivityDetectionKit
import XCTest
@testable import WebRTCVoiceActivityDetection

final class WebRTCVoiceActivityDetectorTests: XCTestCase {
    func testAggressivenessModesArePinnedAndInvalidModeThrows() throws {
        XCTAssertEqual(WebRTCVADAggressiveness.allCases.map(\.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(try WebRTCVADAggressiveness(validatingMode: 0), .quality)
        XCTAssertEqual(try WebRTCVADAggressiveness(validatingMode: 3), .veryAggressive)
        XCTAssertThrowsError(try WebRTCVADAggressiveness(validatingMode: -1)) { error in
            XCTAssertEqual(
                error as? WebRTCVoiceActivityDetectorError,
                .invalidAggressivenessMode(-1)
            )
        }
        XCTAssertThrowsError(try WebRTCVADAggressiveness(validatingMode: 4)) { error in
            XCTAssertEqual(
                error as? WebRTCVoiceActivityDetectorError,
                .invalidAggressivenessMode(4)
            )
        }
    }

    func testLiveDetectorCreatesInitializesAndAcceptsAllModes() async throws {
        for mode in WebRTCVADAggressiveness.allCases {
            let detector = try WebRTCVoiceActivityDetector(aggressiveness: mode)
            let observation = try await detector.observation(for: silenceFrame(sequence: 0))
            XCTAssertFalse(observation.isSpeech)
            XCTAssertEqual(observation.speechProbability, 0)
        }
    }

    func testAllocationInitializationAndModeErrorsAreMappedAndFreed() throws {
        let allocationFailure = LockedFakeWebRTCVAD(createSucceeds: false)
        XCTAssertThrowsError(
            try WebRTCVoiceActivityDetector(api: allocationFailure.api)
        ) { error in
            XCTAssertEqual(error as? WebRTCVoiceActivityDetectorError, .allocationFailed)
        }
        XCTAssertEqual(allocationFailure.snapshot.freeCount, 0)

        let initializationFailure = LockedFakeWebRTCVAD(initializeResults: [-1])
        XCTAssertThrowsError(
            try WebRTCVoiceActivityDetector(api: initializationFailure.api)
        ) { error in
            XCTAssertEqual(error as? WebRTCVoiceActivityDetectorError, .initializationFailed)
        }
        XCTAssertEqual(initializationFailure.snapshot.freeCount, 1)

        let modeFailure = LockedFakeWebRTCVAD(setModeResults: [-1])
        XCTAssertThrowsError(
            try WebRTCVoiceActivityDetector(
                aggressiveness: .veryAggressive,
                api: modeFailure.api
            )
        ) { error in
            XCTAssertEqual(
                error as? WebRTCVoiceActivityDetectorError,
                .modeConfigurationFailed(3)
            )
        }
        XCTAssertEqual(modeFailure.snapshot.freeCount, 1)
        XCTAssertEqual(modeFailure.snapshot.configuredModes, [3])
    }

    func testCheckedCAllocatorFailureReturnsNilAndMapsToAllocationError() throws {
        let failedAllocation = SGDWebRtcVad_CreateWithFailingAllocation()
        XCTAssertNil(failedAllocation)
        XCTAssertNil(WebRTCVADAPI.handleIfAllocated(failedAllocation))

        let live = WebRTCVADAPI.live
        let allocationFailureAPI = WebRTCVADAPI(
            create: {
                WebRTCVADAPI.handleIfAllocated(
                    SGDWebRtcVad_CreateWithFailingAllocation()
                )
            },
            initialize: live.initialize,
            setMode: live.setMode,
            process: live.process,
            free: live.free
        )

        XCTAssertThrowsError(
            try WebRTCVoiceActivityDetector(api: allocationFailureAPI)
        ) { error in
            XCTAssertEqual(error as? WebRTCVoiceActivityDetectorError, .allocationFailed)
        }
    }

    func testSuccessfulDetectorFreesItsSingleHandleOnDeinit() throws {
        let fake = LockedFakeWebRTCVAD()
        var detector: WebRTCVoiceActivityDetector? = try WebRTCVoiceActivityDetector(api: fake.api)
        XCTAssertNotNil(detector)
        XCTAssertEqual(fake.snapshot.freeCount, 0)

        detector = nil

        XCTAssertEqual(fake.snapshot.freeCount, 1)
    }

    func testInputUsesAlignedDecodedSamplesAndPinnedFormat() async throws {
        var expectedSamples = Array(repeating: Int16(0), count: VADPCMFrame.sampleCount)
        expectedSamples.replaceSubrange(0 ..< 5, with: [Int16.min, -1, 0, 1, Int16.max])
        let frame = try VADPCMFrame(sequence: 42, samples: expectedSamples)
        let fake = LockedFakeWebRTCVAD(processResults: [0])
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)

        _ = try await detector.observation(for: frame)

        let processCall = try XCTUnwrap(fake.snapshot.processCalls.first)
        XCTAssertEqual(processCall.sampleRateHertz, 16_000)
        XCTAssertEqual(processCall.sampleCount, 320)
        XCTAssertEqual(processCall.samples, expectedSamples)
    }

    func testProcessReturnMustBeBinaryAndMapsErrors() async throws {
        let fake = LockedFakeWebRTCVAD(processResults: [-1, 2])
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)

        for sequence in UInt64(0) ... 1 {
            do {
                _ = try await detector.observation(for: silenceFrame(sequence: sequence))
                XCTFail("Expected processing error")
            } catch {
                XCTAssertEqual(
                    error as? WebRTCVoiceActivityDetectorError,
                    .processingFailed(sampleRateHertz: 16_000, sampleCount: 320)
                )
            }
        }
    }

    func testBinaryObservationValuesAreCompatibilitySignalsNotCalibratedProbability() async throws {
        let fake = LockedFakeWebRTCVAD(processResults: [0, 1])
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)

        let silence = try await detector.observation(for: silenceFrame(sequence: 0))
        let speech = try await detector.observation(for: silenceFrame(sequence: 1))

        XCTAssertEqual(
            silence,
            try VoiceActivityObservation(speechProbability: 0, isSpeech: false)
        )
        XCTAssertEqual(
            speech,
            try VoiceActivityObservation(speechProbability: 1, isSpeech: true)
        )
    }

    func testResetReinitializesAndReappliesPinnedMode() async throws {
        let fake = LockedFakeWebRTCVAD(
            initializeResults: [0, 0],
            setModeResults: [0, 0],
            processResults: [0]
        )
        let detector = try WebRTCVoiceActivityDetector(
            aggressiveness: .lowBitrate,
            api: fake.api
        )

        await detector.reset()
        _ = try await detector.observation(for: silenceFrame(sequence: 0))

        XCTAssertEqual(fake.snapshot.initializeCount, 2)
        XCTAssertEqual(fake.snapshot.configuredModes, [1, 1])
    }

    func testResetInitializationFailureIsDeferredUntilObservationAndPersistsUntilResetSucceeds() async throws {
        let fake = LockedFakeWebRTCVAD(
            initializeResults: [0, -1, 0],
            setModeResults: [0, 0],
            processResults: [0]
        )
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)

        await detector.reset()
        for sequence in UInt64(0) ... 1 {
            do {
                _ = try await detector.observation(for: silenceFrame(sequence: sequence))
                XCTFail("Expected deferred initialization failure")
            } catch {
                XCTAssertEqual(error as? WebRTCVoiceActivityDetectorError, .initializationFailed)
            }
        }
        XCTAssertTrue(fake.snapshot.processCalls.isEmpty)

        await detector.reset()
        _ = try await detector.observation(for: silenceFrame(sequence: 2))
        XCTAssertEqual(fake.snapshot.processCalls.count, 1)
    }

    func testResetModeFailureIsDeferredAndDoesNotProcess() async throws {
        let fake = LockedFakeWebRTCVAD(
            initializeResults: [0, 0],
            setModeResults: [0, -1],
            processResults: [0]
        )
        let detector = try WebRTCVoiceActivityDetector(
            aggressiveness: .veryAggressive,
            api: fake.api
        )

        await detector.reset()
        do {
            _ = try await detector.observation(for: silenceFrame(sequence: 0))
            XCTFail("Expected deferred mode failure")
        } catch {
            XCTAssertEqual(
                error as? WebRTCVoiceActivityDetectorError,
                .modeConfigurationFailed(3)
            )
        }
        XCTAssertTrue(fake.snapshot.processCalls.isEmpty)
    }

    func testActorSerializesProcessCalls() async throws {
        let firstEntered = DispatchSemaphore(value: 0)
        let firstRelease = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondRelease = DispatchSemaphore(value: 0)
        let fake = LockedFakeWebRTCVAD(
            processResults: [0, 0],
            processHook: { invocation in
                if invocation == 1 {
                    firstEntered.signal()
                    firstRelease.wait()
                } else {
                    secondEntered.signal()
                    secondRelease.wait()
                }
            }
        )
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)
        let firstFrame = try silenceFrame(sequence: 0)
        let first = Task {
            try await detector.observation(for: firstFrame)
        }
        XCTAssertEqual(wait(firstEntered, timeout: 2), .success)

        let secondFrame = try silenceFrame(sequence: 1)
        let second = Task {
            try await detector.observation(for: secondFrame)
        }
        XCTAssertEqual(wait(secondEntered, timeout: 0.05), .timedOut)
        XCTAssertEqual(fake.snapshot.maximumConcurrentProcessCount, 1)

        firstRelease.signal()
        _ = try await first.value
        XCTAssertEqual(wait(secondEntered, timeout: 2), .success)
        secondRelease.signal()
        _ = try await second.value
        XCTAssertEqual(fake.snapshot.maximumConcurrentProcessCount, 1)
    }

    func testCancellationDuringSynchronousProcessCannotPublishObservation() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fake = LockedFakeWebRTCVAD(
            processResults: [1],
            processHook: { _ in
                entered.signal()
                release.wait()
            }
        )
        let detector = try WebRTCVoiceActivityDetector(api: fake.api)
        let frame = try silenceFrame(sequence: 0)
        let task = Task {
            try await detector.observation(for: frame)
        }
        XCTAssertEqual(wait(entered, timeout: 2), .success)

        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await detector.reset()
        XCTAssertEqual(fake.snapshot.initializeCount, 2)
    }

    func testPinnedSyntheticGoldenFrameSequence() async throws {
        let detector = try WebRTCVoiceActivityDetector(aggressiveness: .aggressive)
        let frames = try (0 ..< 6).map { try silenceFrame(sequence: UInt64($0)) }
            + (6 ..< 18).map { try periodicSyntheticFrame(sequence: UInt64($0)) }
            + (18 ..< 30).map { try silenceFrame(sequence: UInt64($0)) }

        let expected = [
            0, 0, 0, 0, 0, 0,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1,
            0, 0, 0, 0, 0, 0
        ]
        var actual: [Int] = []
        for frame in frames {
            actual.append(try await detector.observation(for: frame).isSpeech ? 1 : 0)
        }

        // This is a deterministic API regression fixture, not speech or quality evidence.
        XCTAssertEqual(actual, expected)

        await detector.reset()
        var afterReset: [Int] = []
        for frame in frames {
            afterReset.append(try await detector.observation(for: frame).isSpeech ? 1 : 0)
        }
        XCTAssertEqual(afterReset, expected)
    }

    private func silenceFrame(sequence: UInt64) throws -> VADPCMFrame {
        try VADPCMFrame(
            sequence: sequence,
            samples: Array(repeating: 0, count: VADPCMFrame.sampleCount)
        )
    }

    private func periodicSyntheticFrame(sequence: UInt64) throws -> VADPCMFrame {
        let samples = (0 ..< VADPCMFrame.sampleCount).map { index in
            (index / 8).isMultiple(of: 2) ? Int16(12_000) : Int16(-12_000)
        }
        return try VADPCMFrame(sequence: sequence, samples: samples)
    }

    private func wait(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }
}

private struct ProcessCall: Sendable {
    let sampleRateHertz: Int
    let sampleCount: Int
    let samples: [Int16]
}

private struct FakeSnapshot: Sendable {
    let initializeCount: Int
    let configuredModes: [Int]
    let processCalls: [ProcessCall]
    let freeCount: Int
    let maximumConcurrentProcessCount: Int
}

private final class LockedFakeWebRTCVAD: @unchecked Sendable {
    private let lock = NSLock()
    private let createSucceeds: Bool
    private var initializeResults: [Int32]
    private var setModeResults: [Int32]
    private var processResults: [Int32]
    private let processHook: (@Sendable (Int) -> Void)?
    private var initializeCount = 0
    private var configuredModes: [Int] = []
    private var processCalls: [ProcessCall] = []
    private var freeCount = 0
    private var activeProcessCount = 0
    private var maximumConcurrentProcessCount = 0

    init(
        createSucceeds: Bool = true,
        initializeResults: [Int32] = [0],
        setModeResults: [Int32] = [0],
        processResults: [Int32] = [0],
        processHook: (@Sendable (Int) -> Void)? = nil
    ) {
        self.createSucceeds = createSucceeds
        self.initializeResults = initializeResults
        self.setModeResults = setModeResults
        self.processResults = processResults
        self.processHook = processHook
    }

    var api: WebRTCVADAPI {
        WebRTCVADAPI(
            create: { [self] in
                createSucceeds ? WebRTCVADHandle(rawValue: OpaquePointer(bitPattern: 1)!) : nil
            },
            initialize: { [self] _ in
                lock.withLock {
                    initializeCount += 1
                    return pop(&initializeResults, fallback: 0)
                }
            },
            setMode: { [self] _, mode in
                lock.withLock {
                    configuredModes.append(mode)
                    return pop(&setModeResults, fallback: 0)
                }
            },
            process: { [self] _, rate, samples, count in
                let invocation: Int = lock.withLock {
                    activeProcessCount += 1
                    maximumConcurrentProcessCount = max(
                        maximumConcurrentProcessCount,
                        activeProcessCount
                    )
                    processCalls.append(
                        ProcessCall(
                            sampleRateHertz: rate,
                            sampleCount: count,
                            samples: Array(
                                UnsafeBufferPointer(start: samples, count: count)
                            )
                        )
                    )
                    return processCalls.count
                }
                processHook?(invocation)
                return lock.withLock {
                    activeProcessCount -= 1
                    return pop(&processResults, fallback: 0)
                }
            },
            free: { [self] _ in
                lock.withLock {
                    freeCount += 1
                }
            }
        )
    }

    var snapshot: FakeSnapshot {
        lock.withLock {
            FakeSnapshot(
                initializeCount: initializeCount,
                configuredModes: configuredModes,
                processCalls: processCalls,
                freeCount: freeCount,
                maximumConcurrentProcessCount: maximumConcurrentProcessCount
            )
        }
    }

    private func pop(_ values: inout [Int32], fallback: Int32) -> Int32 {
        values.isEmpty ? fallback : values.removeFirst()
    }
}
