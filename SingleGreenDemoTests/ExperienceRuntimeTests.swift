import XCTest
@testable import SingleGreenDemo

@MainActor
final class ExperienceRuntimeTests: XCTestCase {
    func testDefaultExperienceIsSystemStatus() {
        let runtime = ExperienceRuntime()

        XCTAssertEqual(runtime.selectedKind, .systemStatus)
        XCTAssertEqual(runtime.scene.presentation, .compact)
        XCTAssertEqual(runtime.availableKinds.count, 4)
        XCTAssertFalse(runtime.availableKinds.contains(.conversation))
    }

    func testNavigationMovesForwardAndResetsWhenReactivated() async {
        let runtime = ExperienceRuntime()
        await runtime.activate(.navigation)
        let firstSceneID = runtime.scene.sceneID

        await runtime.handle(.swipeDown)
        XCTAssertNotEqual(runtime.scene.sceneID, firstSceneID)

        await runtime.activate(.systemStatus)
        await runtime.activate(.navigation)
        XCTAssertEqual(runtime.scene.sceneID, firstSceneID)
    }

    func testNotificationCanBeTriggeredAndDismissed() async {
        let runtime = ExperienceRuntime()
        await runtime.activate(.notification)

        await runtime.handle(.triggerAlert)
        XCTAssertEqual(runtime.scene.presentation, .alert)

        await runtime.handle(.tap)
        XCTAssertEqual(runtime.scene.presentation, .compact)
    }

    func testActivatingAnotherExperienceAwaitsConversationCleanup() async {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let conversation = AIConversationExperience(controller: controller)
        let runtime = ExperienceRuntime(sessions: [conversation, NavigationExperience()])

        await conversation.handle(.tap)
        XCTAssertEqual(controller.state, .failed)

        await runtime.activate(.navigation)

        XCTAssertEqual(runtime.selectedKind, .navigation)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testRuntimeReceivesBackgroundConversationSnapshot() async {
        let controller = VoiceConversationController(dependencies: missingAIConfiguration())
        let conversation = AIConversationExperience(controller: controller)
        let runtime = ExperienceRuntime(sessions: [conversation])

        await controller.toggleConversation()
        await waitUntil { runtime.scene.revision == controller.scene.revision }

        XCTAssertEqual(runtime.scene, controller.scene)
        XCTAssertEqual(runtime.primaryActionTitle, controller.primaryActionTitle)
        XCTAssertEqual(runtime.lastEventDescription, controller.lastEventDescription)
        XCTAssertEqual(runtime.lastEventDescription, VoiceConversationState.failed.rawValue)
    }

    func testDisplayProfileUsesNormalizedViewport() {
        let profile = DisplayProfile.simulatorDefault

        XCTAssertEqual(profile.id, "simulator.default.v1")
        XCTAssertGreaterThan(profile.viewport.width, 0)
        XCTAssertLessThanOrEqual(profile.viewport.x + profile.viewport.width, 1)
        XCTAssertLessThanOrEqual(profile.viewport.y + profile.viewport.height, 1)
    }

    func testConversationControllerStartsWithActionableHUD() {
        let controller = VoiceConversationController(settings: AISettings())

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.primaryActionTitle, "开始对话")
        XCTAssertTrue(controller.allowsPrimaryAction)
        XCTAssertEqual(controller.scene.sceneID, "ai_conversation")
        XCTAssertNotNil(controller.scene.elements.first { $0.id == "user_transcript" })
        XCTAssertNotNil(controller.scene.elements.first { $0.id == "assistant_reply" })
    }

    func testConversationBusyStatesDisableRepeatedPrimaryAction() {
        XCTAssertFalse(VoiceConversationState.connecting.allowsPrimaryAction)
        XCTAssertFalse(VoiceConversationState.recognizing.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.thinking.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.searching.allowsPrimaryAction)
        XCTAssertTrue(VoiceConversationState.listening.allowsPrimaryAction)
    }

    func testConversationIncludesSearchingPresentationState() {
        XCTAssertTrue(VoiceConversationState.searching.allowsPrimaryAction)
        XCTAssertEqual(VoiceConversationState.searching.displayName, "AI 正在联网搜索")
        XCTAssertEqual(VoiceConversationState.searching.systemImage, "globe")
    }

    func testSearchConfigurationOnlyRequiresKeyWhenEnabled() {
        let settings = AISettings()
        let originalEnabled = settings.enableSearch
        let originalKey = settings.bochaAPIKey
        defer {
            settings.enableSearch = originalEnabled
            settings.bochaAPIKey = originalKey
        }

        settings.enableSearch = false
        settings.bochaAPIKey = ""
        XCTAssertTrue(settings.isSearchConfigured)

        settings.enableSearch = true
        XCTAssertFalse(settings.isSearchConfigured)

        settings.bochaAPIKey = "bocha-test-key"
        XCTAssertTrue(settings.isSearchConfigured)
    }

    func testAISettingsParsesHotwordsFromCommonSeparators() {
        let settings = AISettings()
        let original = settings.hotwordsText
        defer { settings.hotwordsText = original }

        settings.hotwordsText = "单绿眼镜，豆包 DeepSeek\n产品经理"

        XCTAssertEqual(settings.hotwords, ["单绿眼镜", "豆包", "DeepSeek", "产品经理"])
    }

    func testKeychainHelperRoundTripsSecret() {
        let key = "tests.\(UUID().uuidString)"
        defer { KeychainHelper.delete(key) }

        XCTAssertTrue(KeychainHelper.save("test-secret", forKey: key))
        XCTAssertEqual(KeychainHelper.load(key), "test-secret")
        XCTAssertTrue(KeychainHelper.delete(key))
        XCTAssertNil(KeychainHelper.load(key))
    }

    private func missingAIConfiguration() -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            configuration: {
                AIConversationConfiguration(
                    speechAPIKey: "",
                    asrResourceID: "",
                    asrLanguage: "zh-CN",
                    hotwords: [],
                    handsFree: false,
                    llmAPIKey: "",
                    llmModel: "",
                    enableSearch: false,
                    bochaAPIKey: ""
                )
            },
            makeSpeechSession: { _ in fatalError("配置缺失时不应创建 ASR") },
            makeAgent: { _ in fatalError("配置缺失时不应创建 Agent") },
            requestMicrophonePermission: { false },
            now: { Date(timeIntervalSince1970: 0) },
            sleep: { _ in }
        )
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}
