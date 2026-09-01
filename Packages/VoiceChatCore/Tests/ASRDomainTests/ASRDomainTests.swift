import ASRDomain
import VoiceActivityDetectionKit
import XCTest

final class ASRDomainTests: XCTestCase {
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
        let segmentation = try VADSegmentationPolicy(
            preRollFrameCount: 3,
            onsetWindowFrameCount: 3,
            onsetRequiredSpeechFrameCount: 2,
            endpointSilenceFrameCount: 2,
            maximumSegmentFrameCount: 100
        )
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

    func testDomainEventsAndFailuresRemainProviderNeutralValues() {
        let failure = ASRFailure(code: .networkUnavailable)
        let states: [ASRSessionState] = [.idle, .starting, .failed(failure)]
        let events: [VoiceActivatedASREvent] = [
            .state(.armed),
            .state(.failed(failure)),
            .noSpeech
        ]

        XCTAssertEqual(states.last, .failed(failure))
        XCTAssertEqual(events.last, .noSpeech)
        XCTAssertNil(failure.userSafeMessage)
    }
}
