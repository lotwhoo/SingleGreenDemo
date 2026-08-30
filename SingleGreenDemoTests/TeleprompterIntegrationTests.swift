import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class TeleprompterIntegrationTests: XCTestCase {
    func testScriptDraftPersistsLocallyAndClampsToCoreLimit() {
        let suiteName = "TeleprompterIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = TeleprompterSettings(defaults: defaults)
        XCTAssertFalse(first.allowsCloudSpeechRecognition)
        XCTAssertEqual(first.scriptConfigurationRevision, 0)
        first.scriptDraft = String(repeating: "字", count: TeleprompterLimits.maximumScriptCharacters + 10)
        first.allowsCloudSpeechRecognition = true
        first.applyScriptDraft()

        XCTAssertEqual(first.scriptDraft.count, TeleprompterLimits.maximumScriptCharacters)
        XCTAssertEqual(first.scriptConfigurationRevision, 1)
        let restored = TeleprompterSettings(defaults: defaults)
        XCTAssertEqual(restored.scriptDraft, first.scriptDraft)
        XCTAssertTrue(restored.allowsCloudSpeechRecognition)
        XCTAssertEqual(restored.scriptConfigurationRevision, 0)
    }

    func testSpeechCredentialLeaseIsCapabilityScopedAndRedactsSecret() {
        let lease = SpeechCredentialLease(
            apiKey: "speech-fixture-secret",
            expiresAt: .distantFuture
        )

        XCTAssertTrue(lease.isUsable(at: .now, minimumRemainingLifetime: 0))
        XCTAssertFalse(lease.description.contains("speech-fixture-secret"))
    }

    func testTeleprompterLivePreparationUsesOnlySpeechScopedProvider() async throws {
        let provider = TeleprompterSpeechCredentialFixture()
        let configuration = TeleprompterSpeechConfigurationFixture(
            value: TeleprompterSpeechConfiguration(
                resourceID: "speech-resource",
                language: "zh-CN",
                hotwords: ["single green"]
            )
        )
        let dependencies = LiveSpeechInputComposition.makeTeleprompterDependencies(
            configurationProvider: { configuration.value },
            speechCredentialProvider: provider,
            cloudSpeechRecognitionAllowed: { true }
        )

        _ = try await dependencies.prepareSpeechSession()
        configuration.value = TeleprompterSpeechConfiguration(
            resourceID: "updated-resource",
            language: "en-US",
            hotwords: ["updated"]
        )
        _ = try await dependencies.prepareSpeechSession()

        let leaseRequestCount = await provider.leaseRequestCount
        XCTAssertEqual(leaseRequestCount, 2)

        configuration.value = TeleprompterSpeechConfiguration(
            resourceID: "",
            language: "zh-CN",
            hotwords: []
        )
        do {
            _ = try await dependencies.prepareSpeechSession()
            XCTFail("Expected the latest empty configuration to fail closed")
        } catch let error as ConversationPreparationFailure {
            XCTAssertEqual(error.failureCode, .configurationMissing)
        }
    }
}

private actor TeleprompterSpeechCredentialFixture: SpeechCredentialProvider {
    private(set) var leaseRequestCount = 0

    func speechLease() async throws -> SpeechCredentialLease {
        leaseRequestCount += 1
        return SpeechCredentialLease(apiKey: "speech-only-fixture", expiresAt: .distantFuture)
    }
}

@MainActor
private final class TeleprompterSpeechConfigurationFixture {
    var value: TeleprompterSpeechConfiguration

    init(value: TeleprompterSpeechConfiguration) {
        self.value = value
    }
}
