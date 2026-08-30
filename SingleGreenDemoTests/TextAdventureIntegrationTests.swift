import LLMKit
import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class TextAdventureIntegrationTests: XCTestCase {
    func testTurnInvalidJSONGetsExactlyOneRepair() async throws {
        let transport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: "not json")),
            .success(LLMMessage(role: .assistant, content: validTurnJSON(turn: 1)))
        ])
        let result = try await DeepSeekTextAdventureProvider(transport: transport)
            .proposeTurn(turnRequest(choice: .a))

        XCTAssertEqual(result.turn, 1)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { $0.toolsCount == 0 })
        XCTAssertTrue(transport.requests[1].messages.last?.content?.contains("Repair it once") == true)
    }

    func testTurnOldNarrativePagesSchemaFailsAfterOneRepair() async {
        let old = validTurnJSON(turn: 1).replacingOccurrences(
            of: #""narrative":"绿灯在雨里闪了两次。门后的脚步忽然停住。""#,
            with: #""narrative_pages":["绿灯在雨里闪了两次。门后的脚步忽然停住。"]"#
        )
        let transport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: old)),
            .success(LLMMessage(role: .assistant, content: old))
        ])
        do {
            _ = try await DeepSeekTextAdventureProvider(transport: transport)
                .proposeTurn(turnRequest(choice: .b))
            XCTFail("old schema must fail")
        } catch {
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testTurnRejectsUnsafeChoiceLabelsBeforeRepair() async throws {
        let unsafeChoices = ["**前进**", "www.x", "向前走🚶", "向前\n走"]

        for (index, unsafeChoice) in unsafeChoices.enumerated() {
            let key = index.isMultiple(of: 2) ? "choice_a" : "choice_b"
            let original = key == "choice_a" ? "进入屋内" : "绕到屋后"
            let invalid = replacingChoice(
                in: validTurnJSON(turn: 1),
                key: key,
                original: original,
                with: unsafeChoice
            )
            let transport = TextAdventureTransportStub(responses: [
                .success(LLMMessage(role: .assistant, content: invalid)),
                .success(LLMMessage(role: .assistant, content: validTurnJSON(turn: 1)))
            ])

            let result = try await DeepSeekTextAdventureProvider(transport: transport)
                .proposeTurn(turnRequest(choice: .a))

            XCTAssertEqual(result.turn, 1)
            XCTAssertEqual(transport.requests.count, 2, "unsafe choice: \(unsafeChoice)")
        }
    }

    func testTrendDiscoveryUsesStatelessToolLoopAndReturnsSanitizedSeed() async throws {
        let transport = TextAdventureTransportStub(responses: [
            .success(toolCallMessage()),
            .success(LLMMessage(role: .assistant, content: validTrendJSON))
        ])
        let search = TextAdventureSearchExecutorStub(result: "raw titles and URLs")
        let provider = preparationProvider(transport: transport, search: search)

        let result = try await provider.prepareTrendSeed(
            .init(sessionID: UUID(), seed: 17)
        )

        XCTAssertEqual(result.theme, "人与智能伙伴建立边界")
        XCTAssertEqual(search.callCount, 1)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map(\.toolsCount), [1, 1])
        XCTAssertTrue(transport.requests[1].messages.contains {
            $0.role == .tool && $0.content == "raw titles and URLs"
        })
        XCTAssertTrue(transport.requests[0].messages.first?.content?.contains("MUST call web_search") == true)
    }

    func testTrendFailureOrMissingSearchFallsBackWithoutFrameworkCall() async throws {
        let transport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: validTrendJSON))
        ])
        let provider = preparationProvider(
            transport: transport,
            search: TextAdventureSearchExecutorStub(result: "unused")
        )

        let result = try await provider.prepareTrendSeed(
            .init(sessionID: UUID(), seed: 23)
        )

        XCTAssertEqual(result, .reviewedFallback(seed: 23))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFrameworkInvalidJSONRepairsOnceAndKeepsTrendImmutable() async throws {
        let transport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: "{}")),
            .success(LLMMessage(role: .assistant, content: validFrameworkJSON))
        ])
        let provider = preparationProvider(
            transport: transport,
            search: TextAdventureSearchExecutorStub(result: "unused")
        )
        let trend = try makeTrend()
        let prepared = try await provider.prepareFramework(
            .init(sessionID: UUID(), seed: 88, trendSeed: trend)
        )

        XCTAssertEqual(prepared.storyBrief.seed, 88)
        XCTAssertEqual(prepared.storyBrief.trendSeed, trend)
        XCTAssertEqual(prepared.openingCheckpoint.turn, 0)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { $0.toolsCount == 0 })
        XCTAssertTrue(transport.requests[1].messages.last?.content?.contains("Repair") == true)
    }

    func testFrameworkRejectsUnsafeOpeningChoicesBeforeRepair() async throws {
        let unsafeChoices = ["**前进**", "www.x", "向前走🚶", "向前\n走"]
        let trend = try makeTrend()

        for (index, unsafeChoice) in unsafeChoices.enumerated() {
            let key = index.isMultiple(of: 2) ? "choice_a" : "choice_b"
            let original = key == "choice_a" ? "检查波纹来源" : "询问智能伙伴"
            let invalid = replacingChoice(
                in: validFrameworkJSON,
                key: key,
                original: original,
                with: unsafeChoice
            )
            let transport = TextAdventureTransportStub(responses: [
                .success(LLMMessage(role: .assistant, content: invalid)),
                .success(LLMMessage(role: .assistant, content: validFrameworkJSON))
            ])
            let provider = preparationProvider(
                transport: transport,
                search: TextAdventureSearchExecutorStub(result: "unused")
            )

            let prepared = try await provider.prepareFramework(
                .init(sessionID: UUID(), seed: 88, trendSeed: trend)
            )

            XCTAssertEqual(prepared.storyBrief.seed, 88)
            XCTAssertEqual(transport.requests.count, 2, "unsafe choice: \(unsafeChoice)")
        }
    }

    func testFrameworkRepairFailureUsesReviewedLocalFrameworkAfterTwoCalls() async throws {
        let transport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: "{}")),
            .success(LLMMessage(role: .assistant, content: "{}"))
        ])
        let provider = preparationProvider(
            transport: transport,
            search: TextAdventureSearchExecutorStub(result: "unused")
        )
        let trend = try makeTrend()
        let result = try await provider.prepareFramework(
            .init(sessionID: UUID(), seed: 5, trendSeed: trend)
        )
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(result.storyBrief.seed, 5)
        XCTAssertEqual(result.storyBrief.trendSeed, trend)
        XCTAssertEqual(result.openingCheckpoint.turn, 0)
    }

    func testTrendCancellationPropagatesInsteadOfUsingFallback() async {
        let transport = CancellableTextAdventureTransport()
        let provider = preparationProvider(
            transport: transport,
            search: TextAdventureSearchExecutorStub(result: "unused")
        )
        let task = Task {
            try await provider.prepareTrendSeed(.init(sessionID: UUID(), seed: 3))
        }
        for _ in 0..<100 where !transport.isStarted { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must propagate")
        } catch is CancellationError {
            XCTAssertTrue(transport.observedCancellation)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPromptsPinCurrentContractsAndImmutableFramework() async throws {
        XCTAssertTrue(DeepSeekTextAdventureProvider.systemPromptV2.contains("green-signal-agent/v2"))
        XCTAssertTrue(DeepSeekTextAdventureProvider.systemPromptV2.contains("18-40"))
        XCTAssertTrue(DeepSeekTextAdventureProvider.systemPromptV2.contains("exactly 2"))

        let turnTransport = TextAdventureTransportStub(responses: [
            .success(LLMMessage(role: .assistant, content: validTurnJSON(turn: 1)))
        ])
        _ = try await DeepSeekTextAdventureProvider(transport: turnTransport)
            .proposeTurn(turnRequest(choice: .a))
        let prompt = turnTransport.requests[0].messages[1].content ?? ""
        XCTAssertTrue(prompt.contains("IMMUTABLE_STORY_BRIEF"))
        XCTAssertTrue(prompt.contains("trend_seed"))
        XCTAssertTrue(prompt.contains("CANONICAL_CHECKPOINT"))
    }

    func testAppCatalogStillAddsGameAfterCompatibleBuiltIns() {
        let voice = VoiceConversationController(dependencies: missingAIConfiguration())
        let runtime = ExperienceRuntime(
            sessions: DemoExperienceComposition.sessions(controller: voice)
        )
        XCTAssertEqual(Array(runtime.availableKinds.prefix(5)), ExperienceKind.allCases)
        XCTAssertTrue(runtime.availableKinds.contains(TextAdventureExperience.kind))
        let index = runtime.availableKinds.firstIndex(of: TextAdventureExperience.kind)
        XCTAssertEqual(index.map { runtime.availableDescriptors[$0].actions.count }, 4)
    }

    private func preparationProvider(
        transport: any LLMChatTransport,
        search: any LLMToolExecutor
    ) -> LiveTextAdventureRunPreparationProvider {
        LiveTextAdventureRunPreparationProvider(
            settings: AISettings(),
            credentialProvider: TextAdventureCredentialProviderStub(),
            transportFactory: { _ in transport },
            searchExecutorFactory: { _ in search }
        )
    }

    private func turnRequest(choice: TextAdventureChoice) -> TextAdventureTurnRequest {
        let brief = GreenSignalStoryBriefGenerator.make(seed: 42)
        return TextAdventureTurnRequest(
            sessionID: UUID(),
            storyBrief: brief,
            checkpoint: GreenSignalGame.initialCheckpoint(brief: brief),
            choice: choice
        )
    }

    private func makeTrend() throws -> TextAdventureTrendSeed {
        try TextAdventureTrendSeed(
            theme: "人与智能伙伴建立边界",
            socialTension: "效率与自主选择之间的拉扯",
            emotionalQuestion: "信任应当由谁来证明",
            settingArchetype: "近未来公共空间",
            freshnessNote: "采用长期可用的科技生活议题"
        )
    }

    private func validTurnJSON(turn: Int) -> String {
        """
        {"turn":\(turn),"narrative":"绿灯在雨里闪了两次。门后的脚步忽然停住。","recap":"你追踪信号来到巡山屋。","hint":"先确认退路。","status":{"energy":2,"signal":2,"inventory":["旧接收器"]},"choice_a":"进入屋内","choice_b":"绕到屋后","outcome":"ongoing"}
        """
    }

    private var validTrendJSON: String {
        """
        {"theme":"人与智能伙伴建立边界","social_tension":"效率与自主选择之间的拉扯","emotional_question":"信任应当由谁来证明","setting_archetype":"近未来公共空间","freshness_note":"采用长期可用的科技生活议题"}
        """
    }

    private var validFrameworkJSON: String {
        """
        {"story_brief":{"genre":"near_future_ai","setting":"virtual_archive","protagonist_role":"digital_restorer","motif":"memory_mismatch","pressure":"trust_breakdown","relationship":"ai_companion","plot_structure":"memory_reconstruction","tone":"warm_suspense"},"opening_checkpoint":{"turn":0,"narrative":"绿灯在雨里闪了两次。门后的脚步忽然停住。","recap":"你在档案城发现记忆异常。","hint":"先确认共同记忆。","status":{"energy":3,"signal":1,"inventory":["记忆碎片"]},"choice_a":"检查波纹来源","choice_b":"询问智能伙伴","outcome":"ongoing"}}
        """
    }

    private func replacingChoice(
        in json: String,
        key: String,
        original: String,
        with replacement: String
    ) -> String {
        let encoded = String(data: try! JSONEncoder().encode(replacement), encoding: .utf8)!
        return json.replacingOccurrences(
            of: "\"\(key)\":\"\(original)\"",
            with: "\"\(key)\":\(encoded)"
        )
    }

    private func toolCallMessage() -> LLMMessage {
        let json = #"{"role":"assistant","content":null,"tool_calls":[{"id":"search-1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"近期AI短剧AI漫画社会议题\"}"}}]}"#
        return try! JSONDecoder().decode(LLMMessage.self, from: Data(json.utf8))
    }

    private func missingAIConfiguration() -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            inputMode: { .pushToTalk },
            voiceActivatedInputAvailable: { false },
            prepareSpeechInput: { _ in
                throw ConversationPreparationFailure(
                    userSafeMessage: "对话配置缺失。",
                    failureCode: .configurationMissing
                )
            },
            prepareAgent: {
                throw ConversationPreparationFailure(
                    userSafeMessage: "对话配置缺失。",
                    failureCode: .configurationMissing
                )
            },
            requestMicrophonePermission: { false },
            sleep: { _ in },
            presentationCopy: .singleGreenDemo
        )
    }
}

private struct TextAdventureCredentialProviderStub: ConversationCredentialProvider {
    func lease() async throws -> ConversationCredentialLease {
        ConversationCredentialLease(
            speechAPIKey: "speech-test",
            llmAPIKey: "llm-test",
            searchAPIKey: "search-test",
            agentAccountScope: .init(opaqueID: "account-test"),
            expiresAt: .distantFuture
        )
    }
}

private final class TextAdventureTransportStub: LLMChatTransport, @unchecked Sendable {
    struct Request {
        let messages: [LLMMessage]
        let toolsCount: Int
    }
    private let lock = NSLock()
    private var responses: [Result<LLMMessage, Error>]
    private var storage: [Request] = []
    init(responses: [Result<LLMMessage, Error>]) { self.responses = responses }
    var requests: [Request] { lock.withLock { storage } }

    func completeMessage(
        messages: [LLMMessage], temperature: Double?, maxTokens: Int?, tools: [LLMTool]?
    ) async throws -> LLMMessage {
        try lock.withLock {
            storage.append(Request(messages: messages, toolsCount: tools?.count ?? 0))
            return try responses.removeFirst().get()
        }
    }
    func completeMessageStreaming(
        messages: [LLMMessage], temperature: Double?, maxTokens: Int?, tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class TextAdventureSearchExecutorStub: LLMToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private let result: String
    init(result: String) { self.result = result }
    var callCount: Int { lock.withLock { storage } }
    var toolDefinitions: [LLMTool] {
        [LLMTool(function: .init(name: "web_search", description: "search", parameters: [:]))]
    }
    func execute(_ call: LLMToolCall) async throws -> String {
        lock.withLock { storage += 1 }
        return result
    }
}

private final class CancellableTextAdventureTransport: LLMChatTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    var observedCancellation: Bool { lock.withLock { cancelled } }
    var isStarted: Bool { lock.withLock { started } }
    func completeMessage(
        messages: [LLMMessage], temperature: Double?, maxTokens: Int?, tools: [LLMTool]?
    ) async throws -> LLMMessage {
        lock.withLock { started = true }
        do {
            try await Task.sleep(for: .seconds(30))
            return LLMMessage(role: .assistant, content: "unused")
        } catch {
            lock.withLock { cancelled = true }
            throw error
        }
    }
    func completeMessageStreaming(
        messages: [LLMMessage], temperature: Double?, maxTokens: Int?, tools: [LLMTool]?
    ) -> AsyncThrowingStream<LLMStreamingEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
