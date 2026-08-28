import XCTest
@testable import VoiceActivityDetectionKit

final class VADSegmentationPolicyTests: XCTestCase {
    func testAcceptsBoundaryValidPolicy() throws {
        let policy = try VADSegmentationPolicy(
            preRollFrameCount: 1,
            onsetWindowFrameCount: 1,
            onsetRequiredSpeechFrameCount: 1,
            endpointSilenceFrameCount: 1,
            maximumSegmentFrameCount: 1
        )
        XCTAssertEqual(policy.preRollFrameCount, 1)
        XCTAssertEqual(policy.maximumSegmentFrameCount, 1)
    }

    func testRejectsInvalidPreRollAndOnsetValues() {
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 0,
                onsetWindowFrameCount: 1,
                onsetRequiredSpeechFrameCount: 1,
                endpointSilenceFrameCount: 1,
                maximumSegmentFrameCount: 1
            )
        )
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 2,
                onsetWindowFrameCount: 3,
                onsetRequiredSpeechFrameCount: 2,
                endpointSilenceFrameCount: 1,
                maximumSegmentFrameCount: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? VADSegmentationPolicyError,
                .preRollShorterThanOnsetWindow(preRoll: 2, onsetWindow: 3)
            )
        }
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 3,
                onsetWindowFrameCount: 3,
                onsetRequiredSpeechFrameCount: 4,
                endpointSilenceFrameCount: 1,
                maximumSegmentFrameCount: 3
            )
        )
    }

    func testRejectsInvalidEndpointAndMaximumDurationValues() {
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 3,
                onsetWindowFrameCount: 3,
                onsetRequiredSpeechFrameCount: 2,
                endpointSilenceFrameCount: 0,
                maximumSegmentFrameCount: 3
            )
        )
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 3,
                onsetWindowFrameCount: 3,
                onsetRequiredSpeechFrameCount: 2,
                endpointSilenceFrameCount: 1,
                maximumSegmentFrameCount: 2
            )
        )
        XCTAssertThrowsError(
            try VADSegmentationPolicy(
                preRollFrameCount: 3,
                onsetWindowFrameCount: 3,
                onsetRequiredSpeechFrameCount: 2,
                endpointSilenceFrameCount: 1,
                maximumSegmentFrameCount: VADSegmentationPolicy.maximumSegmentFrameCount + 1
            )
        )
    }
}
