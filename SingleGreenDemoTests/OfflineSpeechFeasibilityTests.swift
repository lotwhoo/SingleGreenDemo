#if INTERNAL_DIAGNOSTICS
import Speech
import XCTest
@testable import SingleGreenDemo

final class OfflineSpeechFeasibilityTests: XCTestCase {
    func testDiagnosticLineContainsOnlyReviewedCapabilityMeasurements() {
        let snapshot = OfflineSpeechCapabilitySnapshot(
            requestedLocaleIdentifier: "zh-CN",
            resolvedLocaleIdentifier: "zh-Hans-CN",
            transcriberAvailable: true,
            assetStatus: .installed,
            sampleRate: 16_000,
            channelCount: 1,
            preparationStatus: .succeeded,
            preparationMilliseconds: 42
        )

        XCTAssertEqual(
            snapshot.diagnosticLine,
            "requested_locale=zh-CN resolved_locale=zh-Hans-CN available=true "
                + "asset=installed sample_rate_hz=16000 channels=1 "
                + "preparation=succeeded preparation_ms=42"
        )
        XCTAssertFalse(snapshot.diagnosticLine.contains("transcript"))
        XCTAssertFalse(snapshot.diagnosticLine.contains("audio="))
        XCTAssertFalse(snapshot.diagnosticLine.contains("api_key"))
    }

    func testMapsEveryKnownAssetInventoryStatus() {
        XCTAssertEqual(AppleOfflineSpeechCapabilityChecker.map(.unsupported), .unsupported)
        XCTAssertEqual(AppleOfflineSpeechCapabilityChecker.map(.supported), .supported)
        XCTAssertEqual(AppleOfflineSpeechCapabilityChecker.map(.downloading), .downloading)
        XCTAssertEqual(AppleOfflineSpeechCapabilityChecker.map(.installed), .installed)
    }
}
#endif
