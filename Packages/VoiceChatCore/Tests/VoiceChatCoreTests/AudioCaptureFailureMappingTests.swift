import AudioCaptureApple
import XCTest
@testable import VoiceChatCore

final class AudioCaptureFailureMappingTests: XCTestCase {
    func testAudioAndProviderFailuresMapToTypedPrivacySafeCodes() {
        XCTAssertEqual(ASRFailure.audioCapture(.noInput).code, .audioUnavailable)
        XCTAssertEqual(ASRFailure.audioCapture(.engineFailed).code, .audioUnavailable)
        XCTAssertEqual(ASRFailure.audioCapture(.converterFailed).code, .audioUnavailable)
        XCTAssertEqual(ASRFailure.audioSystemEvent(.interruptionBegan)?.code, .audioInterrupted)
        XCTAssertEqual(ASRFailure.audioSystemEvent(.routeChanged)?.code, .audioUnavailable)
        XCTAssertNil(ASRFailure.audioSystemEvent(.interruptionEnded))
        XCTAssertEqual(ASRFailure.providerStatus(401).code, .unauthorized)
        XCTAssertEqual(ASRFailure.providerStatus(403).code, .unauthorized)
        XCTAssertEqual(ASRFailure.providerStatus(500).code, .protocolFailure)
        for code: ASRFailure.Code in [
            .voiceActivityUnavailable,
            .voiceActivityProcessingFailed,
            .audioCaptureOverrun,
            .uploadBackpressureExceeded
        ] {
            let failure = ASRFailure.categorized(code)
            XCTAssertEqual(failure.code, code)
            XCTAssertFalse(failure.userSafeMessage?.isEmpty ?? true)
        }
    }
}
