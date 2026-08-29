import VoiceActivityDetectionKit
import XCTest
@testable import VoiceChatCore

final class VoiceActivatedASRRunStateTests: XCTestCase {
    func testPendingCountIncludesQueuedPendingAndInFlightFrames() throws {
        var state = VoiceActivatedASRRunState()
        state.enqueueFrame(try makeFrame(0))
        XCTAssertTrue(state.appendUploadFrames(
            [try makeFrame(1), try makeFrame(2)],
            maximumPendingFrameCount: 4
        ))
        state.beginUpload(frameCount: 1)

        XCTAssertEqual(state.pendingFrameCount, 4)
        XCTAssertFalse(state.canAcceptFrame(maximumPendingFrameCount: 4))
    }

    func testFrameQueuePreservesFIFOOrder() throws {
        var state = VoiceActivatedASRRunState()
        state.enqueueFrame(try makeFrame(1))
        state.enqueueFrame(try makeFrame(2))

        XCTAssertEqual(state.dequeueFrame()?.sequence, 1)
        XCTAssertEqual(state.dequeueFrame()?.sequence, 2)
        XCTAssertNil(state.dequeueFrame())
    }

    func testFullUploadBatchesPreserveFIFOAndLeaveRemainder() throws {
        var state = VoiceActivatedASRRunState()
        XCTAssertTrue(state.appendUploadFrames(
            try (0..<5).map(makeFrame),
            maximumPendingFrameCount: 5
        ))

        XCTAssertEqual(state.takeFullUploadBatch(frameCount: 2)?.map(\.sequence), [0, 1])
        XCTAssertEqual(state.takeFullUploadBatch(frameCount: 2)?.map(\.sequence), [2, 3])
        XCTAssertNil(state.takeFullUploadBatch(frameCount: 2))
        XCTAssertEqual(state.takePendingUploadFrames()?.map(\.sequence), [4])
        XCTAssertNil(state.takePendingUploadFrames())
    }

    func testRejectedUploadAppendRemainsBufferedUntilFailureCleanup() throws {
        var state = VoiceActivatedASRRunState()

        XCTAssertFalse(state.appendUploadFrames(
            try (0..<3).map(makeFrame),
            maximumPendingFrameCount: 2
        ))
        XCTAssertEqual(state.pendingFrameCount, 3)

        state.clearBufferedFrames()
        XCTAssertEqual(state.pendingFrameCount, 0)
    }

    func testResetClearsEveryPerRunFact() throws {
        var state = VoiceActivatedASRRunState()
        state.acceptingFrames = true
        state.speechStarted = true
        state.transportAttempted = true
        state.sourceStopExpected = true
        state.processedBeforeOnset = 12
        state.manualFinishRequested = true
        state.finalizationStarted = true
        state.enqueueFrame(try makeFrame(0))
        XCTAssertTrue(state.appendUploadFrames(
            [try makeFrame(1)],
            maximumPendingFrameCount: 2
        ))
        state.beginUpload(frameCount: 1)

        state.reset()

        XCTAssertEqual(state, VoiceActivatedASRRunState())
    }

    private func makeFrame(_ sequence: Int) throws -> VADPCMFrame {
        try makeFrame(UInt64(sequence))
    }

    private func makeFrame(_ sequence: UInt64) throws -> VADPCMFrame {
        try VADPCMFrame(
            sequence: sequence,
            littleEndianBytes: Array(repeating: 0, count: VADPCMFrame.byteCount)
        )
    }
}
