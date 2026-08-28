import XCTest
@testable import VoiceActivityDetectionKit

final class VADPCMFrameTests: XCTestCase {
    func testFormatConstantsPinExactASRFrameContract() {
        XCTAssertEqual(VADPCMFrame.sampleRateHertz, 16_000)
        XCTAssertEqual(VADPCMFrame.channelCount, 1)
        XCTAssertEqual(VADPCMFrame.durationMilliseconds, 20)
        XCTAssertEqual(VADPCMFrame.sampleCount, 320)
        XCTAssertEqual(VADPCMFrame.byteCount, 640)
    }

    func testRejectsIncorrectByteAndSampleCounts() {
        XCTAssertThrowsError(
            try VADPCMFrame(sequence: 1, littleEndianBytes: Array(repeating: 0, count: 639))
        ) { error in
            XCTAssertEqual(
                error as? VADPCMFrameError,
                .invalidByteCount(expected: 640, actual: 639)
            )
        }
        XCTAssertThrowsError(
            try VADPCMFrame(sequence: 1, samples: Array(repeating: 0, count: 321))
        ) { error in
            XCTAssertEqual(
                error as? VADPCMFrameError,
                .invalidSampleCount(expected: 320, actual: 321)
            )
        }
    }

    func testSampleInitializerProducesAndDecodesSignedLittleEndianPCM() throws {
        var samples = Array(repeating: Int16(0), count: VADPCMFrame.sampleCount)
        samples[0] = 0x1234
        samples[1] = -2

        let frame = try VADPCMFrame(sequence: 42, samples: samples)

        XCTAssertEqual(frame.sequence, 42)
        XCTAssertEqual(Array(frame.littleEndianBytes.prefix(4)), [0x34, 0x12, 0xfe, 0xff])
        XCTAssertEqual(frame.samples, samples)
    }

    func testObservationRejectsNonFiniteAndOutOfRangeProbabilities() {
        XCTAssertThrowsError(
            try VoiceActivityObservation(speechProbability: .nan, isSpeech: false)
        ) { error in
            XCTAssertEqual(error as? VoiceActivityObservationError, .nonFiniteProbability)
        }
        XCTAssertThrowsError(
            try VoiceActivityObservation(speechProbability: -0.01, isSpeech: false)
        ) { error in
            XCTAssertEqual(
                error as? VoiceActivityObservationError,
                .probabilityOutOfRange(-0.01)
            )
        }
        XCTAssertThrowsError(
            try VoiceActivityObservation(speechProbability: 1.01, isSpeech: true)
        )
    }
}
