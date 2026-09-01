import AVFoundation
import os
import XCTest
@testable import AudioCaptureApple

final class AudioCaptureTests: XCTestCase {
    func testSnapshotRoundTripsMonoAndStereoInterleavedAndNonInterleavedPCM() throws {
        for channelCount: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let source = try makeBuffer(channelCount: channelCount, interleaved: interleaved)
                let snapshot = try XCTUnwrap(PCMBufferSnapshot(source))
                let restored = try XCTUnwrap(snapshot.makeBuffer())

                XCTAssertEqual(restored.frameLength, source.frameLength)
                assertEqualASBD(restored.format, source.format)
                assertEqualChannelLayout(restored.format.channelLayout, source.format.channelLayout)
                assertEqualAudioBuffers(restored, source)
            }
        }
    }

    func testConversionDiagnosticReportsOnlySanitizedFailureCategory() {
        let diagnostics = OSAllocatedUnfairLock(initialState: [AudioCapture.Diagnostic]())
        let capture = AudioCapture { diagnostic in
            diagnostics.withLock { $0.append(diagnostic) }
        }

        capture.reportConversionFailure(.converterError)

        XCTAssertEqual(diagnostics.withLock { $0 }, [.conversionFailed(.converterError)])
    }

    func testAudioSystemSeamReportsOnlyCoarsePrivacySafeEvents() {
        let diagnostics = OSAllocatedUnfairLock(initialState: [AudioCapture.Diagnostic]())
        let capture = AudioCapture { diagnostic in
            diagnostics.withLock { $0.append(diagnostic) }
        }

        capture.reportAudioSystemEvent(.interruptionBegan)
        capture.reportAudioSystemEvent(.interruptionEnded)
        capture.reportAudioSystemEvent(.routeChanged)
        capture.reportAudioSystemEvent(.mediaServicesReset)

        XCTAssertEqual(diagnostics.withLock { $0 }, [
            .audioSystemEvent(.interruptionBegan),
            .audioSystemEvent(.interruptionEnded),
            .audioSystemEvent(.routeChanged),
            .audioSystemEvent(.mediaServicesReset)
        ])
    }

    func testInjectedAudioSystemEventsUseActiveRunTokenAndRejectStaleRunCallbacks() throws {
        let source = RecordingAudioSystemEventSource()
        let runState = AudioCaptureRunState()
        let diagnostics = OSAllocatedUnfairLock(
            initialState: [(UInt64, AudioCapture.Diagnostic)]()
        )
        let bridge = AudioCaptureAudioSystemEventBridge(
            source: source,
            runState: runState,
            diagnosticHandler: nil,
            runDiagnosticHandler: { token, diagnostic in
                diagnostics.withLock { $0.append((token, diagnostic)) }
            }
        )
        let firstRunID = try XCTUnwrap(runState.begin(
            callbackToken: 11,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in },
            levelHandler: nil
        ))
        bridge.start(captureRunID: firstRunID)
        source.emit(.interruptionBegan, subscription: 0)
        source.emit(.interruptionEnded, subscription: 0)
        source.emit(.routeChanged, subscription: 0)
        source.emit(.mediaServicesReset, subscription: 0)

        _ = runState.stop(captureRunID: firstRunID, flushRemainder: false)
        bridge.stop()
        let secondRunID = try XCTUnwrap(runState.begin(
            callbackToken: 22,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in },
            levelHandler: nil
        ))
        bridge.start(captureRunID: secondRunID)
        source.emit(.interruptionBegan, subscription: 0)
        source.emit(.routeChanged, subscription: 1)

        let recorded = diagnostics.withLock { $0 }
        XCTAssertEqual(recorded.map(\.0), [11, 11, 11, 11, 22])
        XCTAssertEqual(recorded.map(\.1), [
            .audioSystemEvent(.interruptionBegan),
            .audioSystemEvent(.interruptionEnded),
            .audioSystemEvent(.routeChanged),
            .audioSystemEvent(.mediaServicesReset),
            .audioSystemEvent(.routeChanged)
        ])
        XCTAssertEqual(source.startCount, 2)
        XCTAssertEqual(source.stopCount, 1)
        _ = runState.stop(captureRunID: secondRunID, flushRemainder: false)
        bridge.stop()
    }

    func testAudioSessionActivationFailureAlwaysAttemptsDeactivation() {
        let activation = RecordingAudioSessionActivation(failActivation: true)
        let lifecycle = AudioSessionActivationLifecycle(activation: activation)

        XCTAssertThrowsError(try lifecycle.withActivatedSession {})
        lifecycle.deactivate()

        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
    }

    func testAudioSessionLifecycleActivationAndDeactivationAreIdempotent() throws {
        let activation = RecordingAudioSessionActivation()
        let lifecycle = AudioSessionActivationLifecycle(activation: activation)

        try lifecycle.withActivatedSession {}
        try lifecycle.withActivatedSession {}
        lifecycle.deactivate()
        lifecycle.deactivate()

        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
    }

    func testAudioSessionLifecycleDeinitReleasesActiveSessionExactlyOnce() throws {
        let activation = RecordingAudioSessionActivation()
        var lifecycle: AudioSessionActivationLifecycle? = AudioSessionActivationLifecycle(
            activation: activation
        )

        try lifecycle?.withActivatedSession {}
        lifecycle = nil

        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
    }

    func testRepeatedStopBeforeStartDoesNotDeactivateAudioSession() {
        let activation = RecordingAudioSessionActivation()
        let capture = AudioCapture(audioSessionActivation: activation)

        capture.stop(flushRemainder: false)
        capture.stop(flushRemainder: false)

        XCTAssertTrue(activation.operations.isEmpty)
    }

    func testInvalidCaptureContractDoesNotActivateAudioSession() {
        let activation = RecordingAudioSessionActivation()
        let capture = AudioCapture(audioSessionActivation: activation)

        XCTAssertThrowsError(try capture.startRun(
            callbackToken: 1,
            chunkByteCount: 1,
            chunkHandler: { _, _ in }
        ))

        XCTAssertTrue(activation.operations.isEmpty)
    }

    func testCaptureGraphPreparationRunsAfterAudioSessionActivation() {
        let sequence = RecordingOperationSequence()
        let activation = RecordingAudioSessionActivation { operation in
            sequence.append(operation)
        }
        let graphPreparation = FailingAudioCaptureGraphPreparation {
            sequence.append("prepareGraph")
        }
        let eventSource = RecordingAudioSystemEventSource()
        let capture = AudioCapture(
            audioSessionActivation: activation,
            audioSystemEventSource: eventSource,
            graphPreparation: graphPreparation
        )

        XCTAssertThrowsError(try capture.startRun(
            callbackToken: 7,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in }
        )) { error in
            XCTAssertEqual(error as? AudioCapture.CaptureError, .noInput)
        }

        XCTAssertEqual(sequence.operations, ["activate", "prepareGraph", "deactivate"])
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(eventSource.startCount, 1)
        XCTAssertEqual(eventSource.stopCount, 1)
    }

    func testAudioSessionActivationFailureSkipsGraphPreparationAndCleansUpRun() {
        let activation = RecordingAudioSessionActivation(failActivation: true)
        let graphPreparation = FailingAudioCaptureGraphPreparation()
        let eventSource = RecordingAudioSystemEventSource()
        let capture = AudioCapture(
            audioSessionActivation: activation,
            audioSystemEventSource: eventSource,
            graphPreparation: graphPreparation
        )

        XCTAssertThrowsError(try capture.startRun(
            callbackToken: 9,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in }
        )) { error in
            XCTAssertEqual(error as? AudioCapture.CaptureError, .engineFailed)
        }

        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
        XCTAssertEqual(graphPreparation.prepareCount, 0)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(eventSource.startCount, 1)
        XCTAssertEqual(eventSource.stopCount, 1)
    }

    func testStartupSequenceSubscribesBeforeActivationAndGraphStart() throws {
        let sequence = RecordingOperationSequence()
        let activation = RecordingAudioSessionActivation { operation in
            sequence.append(operation)
        }
        let lifecycle = AudioSessionActivationLifecycle(activation: activation)
        let startup = AudioCaptureStartupSequence(audioSessionLifecycle: lifecycle)

        try startup.start(
            subscribeToAudioSystemEvents: {
                sequence.append("subscribeToEvents")
            },
            unsubscribeFromAudioSystemEvents: {
                sequence.append("unsubscribeFromEvents")
            },
            graphOperation: {
                sequence.append("prepareGraph")
                sequence.append("startEngine")
            }
        )

        XCTAssertEqual(sequence.operations, [
            "subscribeToEvents",
            "activate",
            "prepareGraph",
            "startEngine"
        ])
        lifecycle.deactivate()
    }

    func testStartupSequenceRollsBackSubscriptionAfterGraphFailure() {
        let sequence = RecordingOperationSequence()
        let activation = RecordingAudioSessionActivation { operation in
            sequence.append(operation)
        }
        let startup = AudioCaptureStartupSequence(
            audioSessionLifecycle: AudioSessionActivationLifecycle(activation: activation)
        )

        XCTAssertThrowsError(try startup.start(
            subscribeToAudioSystemEvents: {
                sequence.append("subscribeToEvents")
            },
            unsubscribeFromAudioSystemEvents: {
                sequence.append("unsubscribeFromEvents")
            },
            graphOperation: {
                sequence.append("prepareGraph")
                throw AudioCapture.CaptureError.noInput
            }
        ))

        XCTAssertEqual(sequence.operations, [
            "subscribeToEvents",
            "activate",
            "prepareGraph",
            "deactivate",
            "unsubscribeFromEvents"
        ])
    }

    func testStartupSequenceRollsBackSubscriptionAfterActivationFailure() {
        let sequence = RecordingOperationSequence()
        let activation = RecordingAudioSessionActivation(
            failActivation: true,
            operationHandler: { operation in sequence.append(operation) }
        )
        let startup = AudioCaptureStartupSequence(
            audioSessionLifecycle: AudioSessionActivationLifecycle(activation: activation)
        )

        XCTAssertThrowsError(try startup.start(
            subscribeToAudioSystemEvents: {
                sequence.append("subscribeToEvents")
            },
            unsubscribeFromAudioSystemEvents: {
                sequence.append("unsubscribeFromEvents")
            },
            graphOperation: {
                sequence.append("prepareGraph")
            }
        ))

        XCTAssertEqual(sequence.operations, [
            "subscribeToEvents",
            "activate",
            "deactivate",
            "unsubscribeFromEvents"
        ])
    }

    func testRouteChangePolicySuppressesCategoryConfigurationOnly() {
        XCTAssertFalse(AudioRouteChangeReportingPolicy.shouldReport(isCategoryChange: true))
        XCTAssertTrue(AudioRouteChangeReportingPolicy.shouldReport(isCategoryChange: false))
    }

    func testFailureAfterAudioSessionActivationAlwaysDeactivates() {
        let activation = RecordingAudioSessionActivation()
        let lifecycle = AudioSessionActivationLifecycle(activation: activation)

        XCTAssertThrowsError(try lifecycle.withActivatedSession {
            throw InjectedAudioSessionFailure.afterActivation
        })

        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
    }

    func testSuccessfulAudioSessionActivationStaysActiveUntilExplicitStop() throws {
        let activation = RecordingAudioSessionActivation()
        let lifecycle = AudioSessionActivationLifecycle(activation: activation)

        try lifecycle.withActivatedSession {}
        XCTAssertEqual(activation.operations, ["activate"])
        lifecycle.deactivate()
        XCTAssertEqual(activation.operations, ["activate", "deactivate"])
    }

    func testRunStateRejectsOldCallbacksAfterStopAndRearm() throws {
        let chunks = OSAllocatedUnfairLock(initialState: [(UInt64, Data)]())
        let levels = OSAllocatedUnfairLock(initialState: [(UInt64, Float)]())
        let runState = AudioCaptureRunState()
        let firstRunID = try XCTUnwrap(runState.begin(
            callbackToken: 11,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { token, data in
                chunks.withLock { $0.append((token, data)) }
            },
            levelHandler: { token, level in
                levels.withLock { $0.append((token, level)) }
            }
        ))
        runState.append(Data(repeating: 1, count: 100), captureRunID: firstRunID)
        _ = runState.stop(captureRunID: firstRunID, flushRemainder: false)

        let secondRunID = try XCTUnwrap(runState.begin(
            callbackToken: 22,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { token, data in
                chunks.withLock { $0.append((token, data)) }
            },
            levelHandler: { token, level in
                levels.withLock { $0.append((token, level)) }
            }
        ))

        runState.append(
            Data(repeating: 2, count: AudioCapture.vadFrameBytes),
            captureRunID: firstRunID
        )
        runState.emitLevel(0.9, captureRunID: firstRunID)
        runState.append(
            Data(repeating: 3, count: AudioCapture.vadFrameBytes),
            captureRunID: secondRunID
        )
        runState.emitLevel(0.25, captureRunID: secondRunID)

        let emittedChunks = chunks.withLock { $0 }
        XCTAssertEqual(emittedChunks.count, 1)
        XCTAssertEqual(emittedChunks.first?.0, 22)
        XCTAssertEqual(
            emittedChunks.first?.1,
            Data(repeating: 3, count: AudioCapture.vadFrameBytes)
        )
        XCTAssertEqual(levels.withLock { $0.map(\.0) }, [22])
        XCTAssertEqual(levels.withLock { $0.map(\.1) }, [0.25])
    }

    func testRunStateRejectsDuplicateStartAdmissionUntilStopped() throws {
        let runState = AudioCaptureRunState()
        let firstRunID = try XCTUnwrap(runState.begin(
            callbackToken: 1,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in },
            levelHandler: nil
        ))

        XCTAssertNil(runState.begin(
            callbackToken: 2,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in },
            levelHandler: nil
        ))
        _ = runState.stop(captureRunID: firstRunID, flushRemainder: false)
        XCTAssertNotNil(runState.begin(
            callbackToken: 3,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, _ in },
            levelHandler: nil
        ))
    }

    func testRunStateStopWithoutFlushClearsPendingPCMAndReleasesHandlers() throws {
        final class HandlerLifetime: @unchecked Sendable {}

        let runState = AudioCaptureRunState()
        weak var weakLifetime: HandlerLifetime?
        var firstRunID: UInt64?
        do {
            let lifetime = HandlerLifetime()
            weakLifetime = lifetime
            firstRunID = runState.begin(
                callbackToken: 1,
                chunkByteCount: AudioCapture.vadFrameBytes,
                chunkHandler: { [lifetime] _, _ in _ = lifetime },
                levelHandler: { [lifetime] _, _ in _ = lifetime }
            )
        }
        let validFirstRunID = try XCTUnwrap(firstRunID)
        runState.append(Data(repeating: 7, count: 100), captureRunID: validFirstRunID)
        var stopped = runState.stop(
            captureRunID: validFirstRunID,
            flushRemainder: false
        )
        XCTAssertNil(stopped?.remainder)
        XCTAssertNotNil(weakLifetime)

        stopped = nil
        XCTAssertNil(weakLifetime)

        let chunks = OSAllocatedUnfairLock(initialState: [Data]())
        let secondRunID = try XCTUnwrap(runState.begin(
            callbackToken: 2,
            chunkByteCount: AudioCapture.vadFrameBytes,
            chunkHandler: { _, data in chunks.withLock { $0.append(data) } },
            levelHandler: nil
        ))
        runState.append(
            Data(repeating: 8, count: AudioCapture.vadFrameBytes),
            captureRunID: secondRunID
        )
        XCTAssertEqual(
            chunks.withLock { $0 },
            [Data(repeating: 8, count: AudioCapture.vadFrameBytes)]
        )
    }

    func testSnapshotRoundTripsCustomChannelDescriptionLayout() throws {
        let description = AudioChannelDescription(
            mChannelLabel: kAudioChannelLabel_UseCoordinates,
            mChannelFlags: [.rectangularCoordinates, .meters],
            mCoordinates: (0.25, -0.5, 1.75)
        )
        var rawLayout = AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelDescriptions,
            mChannelBitmap: AudioChannelBitmap(rawValue: 0),
            mNumberChannelDescriptions: 1,
            mChannelDescriptions: (description)
        )
        let channelLayout = try XCTUnwrap(AVAudioChannelLayout(layout: &rawLayout))
        let baseFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        var streamDescription = baseFormat.streamDescription.pointee
        let format = try XCTUnwrap(AVAudioFormat(
            streamDescription: &streamDescription,
            channelLayout: channelLayout
        ))
        let source = try makeFilledBuffer(format: format)

        let snapshot = try XCTUnwrap(PCMBufferSnapshot(source))
        let restored = try XCTUnwrap(snapshot.makeBuffer())

        assertEqualASBD(restored.format, source.format)
        assertEqualChannelLayout(restored.format.channelLayout, source.format.channelLayout)
        assertEqualAudioBuffers(restored, source)
    }

    private func makeBuffer(
        channelCount: AVAudioChannelCount,
        interleaved: Bool
    ) throws -> AVAudioPCMBuffer {
        let baseFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: channelCount,
            interleaved: interleaved
        ))
        var streamDescription = baseFormat.streamDescription.pointee
        let layoutTag = channelCount == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = try XCTUnwrap(AVAudioFormat(
            streamDescription: &streamDescription,
            channelLayout: layout
        ))
        return try makeFilledBuffer(format: format)
    }

    private func makeFilledBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16

        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in buffers.indices {
            let byteCount = Int(buffers[index].mDataByteSize)
            let bytes = Data((0..<byteCount).map { UInt8(($0 + index * 37) % 251) })
            let destination = try XCTUnwrap(buffers[index].mData)
            bytes.copyBytes(
                to: destination.assumingMemoryBound(to: UInt8.self),
                count: bytes.count
            )
        }
        return buffer
    }

    private func assertEqualASBD(
        _ lhs: AVAudioFormat,
        _ rhs: AVAudioFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let left = lhs.streamDescription.pointee
        let right = rhs.streamDescription.pointee
        XCTAssertEqual(left.mSampleRate, right.mSampleRate, file: file, line: line)
        XCTAssertEqual(left.mFormatID, right.mFormatID, file: file, line: line)
        XCTAssertEqual(left.mFormatFlags, right.mFormatFlags, file: file, line: line)
        XCTAssertEqual(left.mBytesPerPacket, right.mBytesPerPacket, file: file, line: line)
        XCTAssertEqual(left.mFramesPerPacket, right.mFramesPerPacket, file: file, line: line)
        XCTAssertEqual(left.mBytesPerFrame, right.mBytesPerFrame, file: file, line: line)
        XCTAssertEqual(left.mChannelsPerFrame, right.mChannelsPerFrame, file: file, line: line)
        XCTAssertEqual(left.mBitsPerChannel, right.mBitsPerChannel, file: file, line: line)
        XCTAssertEqual(left.mReserved, right.mReserved, file: file, line: line)
    }

    private func assertEqualChannelLayout(
        _ lhs: AVAudioChannelLayout?,
        _ rhs: AVAudioChannelLayout?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs?.layoutTag, rhs?.layoutTag, file: file, line: line)
        XCTAssertEqual(lhs?.channelCount, rhs?.channelCount, file: file, line: line)
        XCTAssertEqual(
            lhs?.layout.pointee.mChannelBitmap,
            rhs?.layout.pointee.mChannelBitmap,
            file: file,
            line: line
        )
        XCTAssertEqual(
            lhs?.layout.pointee.mNumberChannelDescriptions,
            rhs?.layout.pointee.mNumberChannelDescriptions,
            file: file,
            line: line
        )
        guard let leftLayout = lhs?.layout.pointee,
              let rightLayout = rhs?.layout.pointee,
              leftLayout.mNumberChannelDescriptions == 1,
              rightLayout.mNumberChannelDescriptions == 1 else { return }
        let left = leftLayout.mChannelDescriptions
        let right = rightLayout.mChannelDescriptions
        XCTAssertEqual(left.mChannelLabel, right.mChannelLabel, file: file, line: line)
        XCTAssertEqual(left.mChannelFlags, right.mChannelFlags, file: file, line: line)
        XCTAssertEqual(left.mCoordinates.0, right.mCoordinates.0, file: file, line: line)
        XCTAssertEqual(left.mCoordinates.1, right.mCoordinates.1, file: file, line: line)
        XCTAssertEqual(left.mCoordinates.2, right.mCoordinates.2, file: file, line: line)
    }

    private func assertEqualAudioBuffers(
        _ lhs: AVAudioPCMBuffer,
        _ rhs: AVAudioPCMBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let left = UnsafeMutableAudioBufferListPointer(lhs.mutableAudioBufferList)
        let right = UnsafeMutableAudioBufferListPointer(rhs.mutableAudioBufferList)
        XCTAssertEqual(left.count, right.count, file: file, line: line)
        guard left.count == right.count else { return }

        for index in left.indices {
            XCTAssertEqual(
                left[index].mNumberChannels,
                right[index].mNumberChannels,
                file: file,
                line: line
            )
            XCTAssertEqual(left[index].mDataByteSize, right[index].mDataByteSize, file: file, line: line)
            let leftData = left[index].mData.map {
                Data(bytes: $0, count: Int(left[index].mDataByteSize))
            }
            let rightData = right[index].mData.map {
                Data(bytes: $0, count: Int(right[index].mDataByteSize))
            }
            XCTAssertEqual(leftData, rightData, file: file, line: line)
        }
    }
}

private enum InjectedAudioSessionFailure: Error {
    case activation
    case afterActivation
}

private final class RecordingAudioSessionActivation: AudioSessionActivating {
    private struct State: Sendable {
        var operations: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failActivation: Bool
    private let operationHandler: ((String) -> Void)?

    init(
        failActivation: Bool = false,
        operationHandler: ((String) -> Void)? = nil
    ) {
        self.failActivation = failActivation
        self.operationHandler = operationHandler
    }

    var operations: [String] {
        state.withLock { $0.operations }
    }

    func activate() throws {
        state.withLock { $0.operations.append("activate") }
        operationHandler?("activate")
        if failActivation { throw InjectedAudioSessionFailure.activation }
    }

    func deactivate() {
        state.withLock { $0.operations.append("deactivate") }
        operationHandler?("deactivate")
    }
}

private final class RecordingOperationSequence {
    private let state = OSAllocatedUnfairLock(initialState: [String]())

    var operations: [String] { state.withLock { $0 } }

    func append(_ operation: String) {
        state.withLock { $0.append(operation) }
    }
}

private final class FailingAudioCaptureGraphPreparation: AudioCaptureGraphPreparing {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let prepareHandler: (() -> Void)?

    init(prepareHandler: (() -> Void)? = nil) {
        self.prepareHandler = prepareHandler
    }

    var prepareCount: Int { state.withLock { $0 } }

    func prepare(engine: AVAudioEngine) throws -> PreparedAudioCaptureGraph {
        state.withLock { $0 += 1 }
        prepareHandler?()
        throw AudioCapture.CaptureError.noInput
    }
}

private final class RecordingAudioSystemEventSource: AudioSystemEventSource, @unchecked Sendable {
    private struct State: Sendable {
        var handlers: [@Sendable (AudioCapture.AudioSystemEvent) -> Void] = []
        var stopCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startCount: Int { state.withLock { $0.handlers.count } }
    var stopCount: Int { state.withLock { $0.stopCount } }

    func start(handler: @escaping @Sendable (AudioCapture.AudioSystemEvent) -> Void) {
        state.withLock { $0.handlers.append(handler) }
    }

    func stop() {
        state.withLock { $0.stopCount += 1 }
    }

    func emit(_ event: AudioCapture.AudioSystemEvent, subscription: Int) {
        let handler = state.withLock { state in
            state.handlers[subscription]
        }
        handler(event)
    }
}
