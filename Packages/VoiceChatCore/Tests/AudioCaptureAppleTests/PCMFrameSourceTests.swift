import ASRDomain
import Foundation
import VoiceActivityDetectionKit
import XCTest
@testable import AudioCaptureApple

final class PCMFrameSourceTests: XCTestCase {
    func testRelayBuildsExactTwentyMillisecondLittleEndianFrames() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 2)
        let run = relay.beginRun()
        let bytes = Data((0..<VADPCMFrame.byteCount).map { UInt8($0 % 251) })

        relay.yieldFrame(bytes, runToken: run.token)
        var iterator = run.streams.frames.makeAsyncIterator()
        let frame = try await iterator.next()

        XCTAssertEqual(frame?.sequence, 0)
        XCTAssertEqual(frame?.littleEndianBytes, Array(bytes))
        XCTAssertEqual(frame?.littleEndianBytes.count, 640)
        relay.finish(runToken: run.token)
    }

    func testRelayRejectsPartialFrameInsteadOfUploadingIt() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 2)
        let run = relay.beginRun()
        relay.yieldFrame(
            Data(repeating: 0, count: VADPCMFrame.byteCount - 1),
            runToken: run.token
        )
        var iterator = run.streams.frames.makeAsyncIterator()

        do {
            _ = try await iterator.next()
            XCTFail("Expected invalid frame failure")
        } catch let failure as PCMFrameSourceFailure {
            XCTAssertEqual(failure, .invalidFrame)
        }
    }

    func testRelayTerminatesWhenBoundedCaptureBufferOverflows() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 1)
        let run = relay.beginRun()
        relay.yieldFrame(
            Data(repeating: 0, count: VADPCMFrame.byteCount),
            runToken: run.token
        )
        relay.yieldFrame(
            Data(repeating: 1, count: VADPCMFrame.byteCount),
            runToken: run.token
        )
        var iterator = run.streams.frames.makeAsyncIterator()

        let retained = try await iterator.next()
        XCTAssertEqual(retained?.sequence, 0)
        do {
            _ = try await iterator.next()
            XCTFail("Expected bounded buffer overflow")
        } catch let failure as PCMFrameSourceFailure {
            XCTAssertEqual(failure, .bufferOverflow)
        }
    }

    func testRelayRejectsOldRunCallbacksAfterRearm() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 2)
        let oldRun = relay.beginRun()
        relay.finish(runToken: oldRun.token)
        let currentRun = relay.beginRun()

        relay.yieldFrame(
            Data(repeating: 1, count: VADPCMFrame.byteCount),
            runToken: oldRun.token
        )
        relay.yieldLevel(0.9, runToken: oldRun.token)
        relay.handle(
            .conversionFailed(.converterError),
            runToken: oldRun.token
        )
        relay.yieldFrame(
            Data(repeating: 2, count: VADPCMFrame.byteCount),
            runToken: currentRun.token
        )
        relay.yieldLevel(0.25, runToken: currentRun.token)

        var frameIterator = currentRun.streams.frames.makeAsyncIterator()
        let frame = try await frameIterator.next()
        var levelIterator = currentRun.streams.levels.makeAsyncIterator()
        let level = await levelIterator.next()

        XCTAssertEqual(frame?.sequence, 0)
        XCTAssertEqual(frame?.littleEndianBytes, Array(repeating: 2, count: 640))
        XCTAssertEqual(level, 0.25)
        relay.finish(runToken: currentRun.token)
    }

    func testRelayPreservesCurrentAudioSystemFailureAndRejectsStaleEventAfterRearm() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 2)
        let oldRun = relay.beginRun()
        relay.finish(runToken: oldRun.token)
        let currentRun = relay.beginRun()

        relay.handle(
            .audioSystemEvent(.mediaServicesReset),
            runToken: oldRun.token
        )
        relay.yieldFrame(
            Data(repeating: 2, count: VADPCMFrame.byteCount),
            runToken: currentRun.token
        )
        var iterator = currentRun.streams.frames.makeAsyncIterator()
        let retainedFrame = try await iterator.next()
        XCTAssertEqual(retainedFrame?.sequence, 0)

        relay.handle(
            .audioSystemEvent(.interruptionBegan),
            runToken: currentRun.token
        )
        do {
            _ = try await iterator.next()
            XCTFail("Expected the active interruption to terminate the frame stream")
        } catch let failure as PCMFrameSourceFailure {
            XCTAssertEqual(failure, .audioSystemEvent(.interruptionBegan))
        }
    }

    func testRelayDoesNotTerminateForInterruptionEnded() async throws {
        let relay = PCMFrameSourceRelay(maximumBufferedFrameCount: 2)
        let run = relay.beginRun()
        relay.handle(.audioSystemEvent(.interruptionEnded), runToken: run.token)
        relay.yieldFrame(
            Data(repeating: 3, count: VADPCMFrame.byteCount),
            runToken: run.token
        )

        var iterator = run.streams.frames.makeAsyncIterator()
        let retainedFrame = try await iterator.next()
        XCTAssertEqual(retainedFrame?.sequence, 0)
        relay.finish(runToken: run.token)
    }

    func testAudioCaptureDefaultsRemainLegacyCompatible() {
        XCTAssertEqual(AudioCapture.vadFrameBytes, VADPCMFrame.byteCount)
        XCTAssertEqual(AudioCapture.chunkBytes, 6_400)
    }
}
