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

    func testLegacyDraftMigratesOnceIntoVersionedEnvelope() throws {
        let suiteName = "TeleprompterLegacyMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyKey = "legacy-script"
        let envelopeKey = "migrated-envelope"
        defaults.set("旧版稿件。", forKey: legacyKey)

        let settings = TeleprompterSettings(
            defaults: defaults,
            scriptStorageKey: legacyKey,
            envelopeStorageKey: envelopeKey
        )
        XCTAssertEqual(settings.scriptDraft, "旧版稿件。")
        XCTAssertNil(defaults.object(forKey: legacyKey))

        let data = try XCTUnwrap(defaults.data(forKey: envelopeKey))
        let envelope = try JSONDecoder().decode(
            TeleprompterLocalArtifactEnvelope.self,
            from: data
        )
        XCTAssertEqual(
            envelope.schemaVersion,
            TeleprompterLocalArtifactEnvelope.currentSchemaVersion
        )
        XCTAssertEqual(envelope.scriptSource, "旧版稿件。")
        XCTAssertNil(envelope.checkpointData)
    }

    func testScriptRepositoryRejectsInvalidOrDuplicateReplacementWithoutOverwriting() {
        let suiteName = "TeleprompterScriptRepository.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TeleprompterSettings(defaults: defaults)

        XCTAssertEqual(settings.replaceScript(with: " 当前稿件。 "), .applied)
        XCTAssertEqual(settings.scriptDraft, "当前稿件。")
        XCTAssertEqual(settings.scriptConfigurationRevision, 1)

        XCTAssertEqual(settings.replaceScript(with: "当前稿件。"), .duplicate)
        XCTAssertEqual(settings.replaceScript(with: " \n\t "), .rejected(.empty))
        XCTAssertEqual(
            settings.replaceScript(with: String(
                repeating: "字",
                count: TeleprompterLimits.maximumScriptCharacters + 1
            )),
            .rejected(.exceedsCharacterLimit(
                maximum: TeleprompterLimits.maximumScriptCharacters
            ))
        )
        XCTAssertEqual(settings.scriptDraft, "当前稿件。")
        XCTAssertEqual(settings.scriptConfigurationRevision, 1)

        settings.scriptDraft = "尚未载入的编辑稿。"
        let parsed = TeleprompterScriptImporter.parse(
            data: Data(settings.scriptDraft.utf8),
            kind: .plainText,
            existingSource: settings.loadedScriptSource
        )
        guard case .imported(let source) = parsed else {
            return XCTFail("An un-applied draft must not make a matching file look loaded.")
        }
        XCTAssertEqual(settings.replaceScript(with: source), .applied)
        XCTAssertEqual(settings.loadedScriptSource, "尚未载入的编辑稿。")
        XCTAssertEqual(settings.scriptConfigurationRevision, 2)
    }

    func testPhoneExplicitCompletionPersistsRestorableEndCheckpoint() async throws {
        let suiteName = "TeleprompterExplicitCompletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TeleprompterSettings(defaults: defaults)
        XCTAssertEqual(settings.replaceScript(with: "第一句。第二句。"), .applied)
        let script = try TeleprompterScript(
            settings.scriptDraft,
            identity: settings.scriptIdentity
        )
        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { throw ServerCredentialError.transportNotConfigured },
                requestMicrophonePermission: { false }
            ),
            checkpointStore: settings
        )

        await controller.complete()

        XCTAssertEqual(controller.state.phase, .completed)
        let restoredSettings = TeleprompterSettings(defaults: defaults)
        let restoredScript = try TeleprompterScript(
            restoredSettings.scriptDraft,
            identity: restoredSettings.scriptIdentity
        )
        let restoredController = TeleprompterController(
            script: restoredScript,
            dependencies: .init(
                prepareSpeechSession: { throw ServerCredentialError.transportNotConfigured },
                requestMicrophonePermission: { false }
            ),
            checkpointStore: restoredSettings
        )
        XCTAssertEqual(restoredController.state.sentenceIndex, 1)
        XCTAssertEqual(
            restoredController.checkpointRestoreResult,
            .restored(.init(
                sentenceIndex: 1,
                utf16Offset: (restoredScript.sentences[1] as NSString).length
            ))
        )
    }

    func testCheckpointPersistsInSingleEnvelopeAndIdenticalWriteIsIdempotent() throws {
        let suiteName = "TeleprompterCheckpointEnvelope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let envelopeKey = "checkpoint-envelope"
        let settings = TeleprompterSettings(
            defaults: defaults,
            envelopeStorageKey: envelopeKey
        )
        settings.scriptDraft = "第一句。第二句。"
        let script = try TeleprompterScript(
            settings.scriptDraft,
            identity: settings.scriptIdentity
        )
        let checkpoint = try XCTUnwrap(TeleprompterCheckpointResolver.makeCheckpoint(
            script: script,
            anchor: .init(sentenceIndex: 1, utf16Offset: 2)
        ))

        XCTAssertEqual(settings.saveCheckpoint(checkpoint), .saved)
        let firstData = defaults.data(forKey: envelopeKey)
        XCTAssertEqual(settings.saveCheckpoint(checkpoint), .unchanged)
        XCTAssertEqual(defaults.data(forKey: envelopeKey), firstData)

        let restored = TeleprompterSettings(
            defaults: defaults,
            envelopeStorageKey: envelopeKey
        )
        let restoredScript = try TeleprompterScript(
            restored.scriptDraft,
            identity: restored.scriptIdentity
        )
        XCTAssertEqual(restored.scriptIdentity, settings.scriptIdentity)
        XCTAssertEqual(restored.loadCheckpoint(for: restoredScript), .loaded(checkpoint))
    }

    func testEditingScriptInvalidatesCheckpointAndDerivedCaches() throws {
        let suiteName = "TeleprompterEditInvalidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let envelopeKey = "edit-envelope"
        let settings = TeleprompterSettings(
            defaults: defaults,
            envelopeStorageKey: envelopeKey
        )
        settings.scriptDraft = "旧稿第一句。"
        let script = try TeleprompterScript(
            settings.scriptDraft,
            identity: settings.scriptIdentity
        )
        let checkpoint = try XCTUnwrap(TeleprompterCheckpointResolver.makeCheckpoint(
            script: script,
            anchor: .init(sentenceIndex: 0, utf16Offset: 2)
        ))
        XCTAssertEqual(settings.saveCheckpoint(checkpoint), .saved)
        settings.replaceDerivedArtifactsForTesting(
            normalizedIndexCache: Data("index".utf8),
            evaluationCache: Data("evaluation".utf8)
        )

        settings.scriptDraft = "新稿第一句。"
        let revised = try TeleprompterScript(
            settings.scriptDraft,
            identity: settings.scriptIdentity
        )
        XCTAssertEqual(settings.loadCheckpoint(for: revised), .missing)
        let envelopeData = try XCTUnwrap(defaults.data(forKey: envelopeKey))
        let envelope = try JSONDecoder().decode(
            TeleprompterLocalArtifactEnvelope.self,
            from: envelopeData
        )
        XCTAssertNil(envelope.checkpointData)
        XCTAssertNil(envelope.normalizedIndexCache)
        XCTAssertNil(envelope.evaluationCache)
    }

    func testCorruptCheckpointFailsClosedWithoutLosingScript() throws {
        let suiteName = "TeleprompterCorruptCheckpoint.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let envelopeKey = "corrupt-checkpoint-envelope"
        var envelope = TeleprompterLocalArtifactEnvelope.empty(
            identity: .init(rawValue: "corrupt-checkpoint-script")
        )
        envelope.scriptSource = "仍然可用的稿件。"
        envelope.checkpointData = Data([0x00, 0x01])
        defaults.set(try JSONEncoder().encode(envelope), forKey: envelopeKey)

        let settings = TeleprompterSettings(
            defaults: defaults,
            envelopeStorageKey: envelopeKey
        )
        let script = try TeleprompterScript(
            settings.scriptDraft,
            identity: settings.scriptIdentity
        )
        XCTAssertEqual(settings.scriptDraft, "仍然可用的稿件。")
        XCTAssertEqual(settings.loadCheckpoint(for: script), .rejected(.corruptData))

        let controller = TeleprompterController(
            script: script,
            dependencies: .init(
                prepareSpeechSession: { throw ServerCredentialError.transportNotConfigured },
                requestMicrophonePermission: { false }
            ),
            checkpointStore: settings
        )
        XCTAssertEqual(controller.state.sentenceIndex, 0)
        XCTAssertEqual(controller.checkpointRestoreResult, .rejected(.corruptData))
    }

    func testAtomicDeleteClearsScriptCheckpointIndexAndEvaluationCache() throws {
        let suiteName = "TeleprompterAtomicDelete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let envelopeKey = "delete-envelope"
        let settings = TeleprompterSettings(
            defaults: defaults,
            envelopeStorageKey: envelopeKey
        )
        settings.scriptDraft = "需要删除的稿件。"
        let identity = settings.scriptIdentity
        let script = try TeleprompterScript(settings.scriptDraft, identity: identity)
        let checkpoint = try XCTUnwrap(TeleprompterCheckpointResolver.makeCheckpoint(
            script: script,
            anchor: .init(sentenceIndex: 0, utf16Offset: 2)
        ))
        XCTAssertEqual(settings.saveCheckpoint(checkpoint), .saved)
        settings.replaceDerivedArtifactsForTesting(
            normalizedIndexCache: Data("index".utf8),
            evaluationCache: Data("evaluation".utf8)
        )

        XCTAssertEqual(settings.deleteScriptArtifacts(for: identity), .deleted)
        XCTAssertEqual(settings.scriptDraft, "")
        XCTAssertNotEqual(settings.scriptIdentity, identity)

        let data = try XCTUnwrap(defaults.data(forKey: envelopeKey))
        let envelope = try JSONDecoder().decode(
            TeleprompterLocalArtifactEnvelope.self,
            from: data
        )
        XCTAssertEqual(envelope.scriptSource, "")
        XCTAssertNil(envelope.checkpointData)
        XCTAssertNil(envelope.normalizedIndexCache)
        XCTAssertNil(envelope.evaluationCache)
        XCTAssertEqual(settings.deleteScriptArtifacts(for: identity), .alreadyDeleted)
    }

    func testTXTAndMarkdownImportReturnTypedResultsWithoutOverwritingOnFailure() {
        let current = "当前仍可使用的稿件。"
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data(" 新导入的 TXT。 ".utf8),
                kind: .plainText,
                existingSource: current
            ),
            .imported(source: "新导入的 TXT。")
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data("# Markdown\n正文。".utf8),
                kind: .markdown,
                existingSource: current
            ),
            .imported(source: "# Markdown\n正文。")
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data(" \n\t ".utf8),
                kind: .plainText,
                existingSource: current
            ),
            .rejected(.empty)
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data([0xff, 0xfe, 0xfd]),
                kind: .plainText,
                existingSource: current
            ),
            .rejected(.invalidUTF8)
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data(String(
                    repeating: "字",
                    count: TeleprompterLimits.maximumScriptCharacters + 1
                ).utf8),
                kind: .plainText,
                existingSource: current
            ),
            .rejected(.exceedsCharacterLimit(
                maximum: TeleprompterLimits.maximumScriptCharacters
            ))
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data("其他格式".utf8),
                kind: .unsupported,
                existingSource: current
            ),
            .rejected(.unsupportedType)
        )
        XCTAssertEqual(
            TeleprompterScriptImporter.parse(
                data: Data("\n当前仍可使用的稿件。\n".utf8),
                kind: .plainText,
                existingSource: current
            ),
            .duplicate
        )
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
