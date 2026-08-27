import XCTest
import StreamingTextKit
@testable import SingleGreenDemo

@MainActor
final class VoiceConversationControllerTests: XCTestCase {
    func testASRToAgentUsesCumulativeTranscriptInsteadOfLastUtterance() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "这是回答")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        XCTAssertEqual(controller.state, .listening)

        session.emit(.transcript("这是完整的问题"))
        session.emit(.utterance("问题"))
        session.emit(.finished)

        await waitUntil { controller.state == .completed }
        XCTAssertEqual(agent.receivedTexts, ["这是完整的问题"])
        XCTAssertEqual(controller.messages.map(\.text), ["这是完整的问题", "这是回答"])
        XCTAssertEqual(controller.assistantReply, "这是回答")
    }

    func testWebSearchToolUpdatesStateBeforeFinalReply() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent(toolName: "web_search")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("今天有什么新闻"))
        session.emit(.finished)

        await waitUntil { controller.state == .searching }
        await waitUntil { agent.isWaiting }
        XCTAssertEqual(controller.state, .searching)

        agent.complete(with: "联网回答")
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.assistantReply, "联网回答")
    }

    func testDuplicateFinishedEventCreatesOnlyOneAgentRequest() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "一次回答")
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("只问一次"))
        session.emit(.finished)
        session.emit(.finished)

        await waitUntil { controller.state == .completed }
        XCTAssertEqual(agent.receivedTexts, ["只问一次"])
        XCTAssertEqual(controller.messages.filter { !$0.isUser }.count, 1)
    }

    func testMissingASRConfigurationFailsBeforeCreatingSession() async {
        let session = FakeSpeechSession()
        var makeSessionCount = 0
        var dependencies = makeDependencies(session: session, agent: FakeConversationAgent(reply: ""))
        dependencies.configuration = { .missingASR }
        dependencies.makeSpeechSession = { _ in
            makeSessionCount += 1
            return session
        }
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(makeSessionCount, 0)
        XCTAssertEqual(controller.lastError, "请先在设置中填写豆包 ASR API Key 和资源 ID。")
    }

    func testDeniedPermissionFailsWithoutStartingASR() async {
        let session = FakeSpeechSession()
        var dependencies = makeDependencies(session: session, agent: FakeConversationAgent(reply: ""))
        dependencies.requestMicrophonePermission = { false }
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(session.startCount, 0)
        XCTAssertEqual(controller.lastError, "未获得麦克风权限，请在系统设置中允许访问。")
    }

    func testASRFailureCancelsSessionAndPublishesError() async {
        let session = FakeSpeechSession()
        let controller = makeController(session: session, agent: FakeConversationAgent(reply: ""))

        await controller.toggleConversation()
        session.emit(.failed("连接断开"))

        await waitUntil { controller.state == .failed }
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(controller.lastError, "语音识别失败：连接断开")
    }

    func testAgentFailureRemovesPendingReplyAndKeepsUserMessage() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(error: TestFailure.agent)
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("失败问题"))
        session.emit(.finished)

        await waitUntil { controller.state == .failed }
        XCTAssertEqual(controller.messages.map(\.text), ["失败问题"])
        XCTAssertEqual(controller.lastError, "AI 回复失败：测试 Agent 失败")
    }

    func testResetCancelsSuspendedReplyAndClearsAgentContext() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("等待中的问题"))
        session.emit(.finished)
        await waitUntil { controller.state == .thinking }
        await waitUntil { agent.isWaiting }

        await controller.resetConversation()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertEqual(agent.clearCount, 1)
        XCTAssertTrue(agent.wasCancelled)
    }

    func testHandsFreeVADUsesInjectedClockAndFinishesRecording() async {
        let session = FakeSpeechSession()
        let time = MutableTime(Date(timeIntervalSince1970: 100))
        var configuration = AIConversationConfiguration.valid
        configuration.handsFree = true
        var dependencies = makeDependencies(session: session, agent: FakeConversationAgent(reply: ""))
        dependencies.configuration = { configuration }
        dependencies.now = { time.value }
        dependencies.sleep = { _ in
            time.value = time.value.addingTimeInterval(2)
            await Task.yield()
        }
        let controller = VoiceConversationController(
            dependencies: dependencies,
            silenceThreshold: 0.03,
            silenceTimeout: 1.5
        )

        await controller.toggleConversation()

        await waitUntil { session.finishCount == 1 }
        XCTAssertEqual(controller.state, .recognizing)
        XCTAssertEqual(session.finishCount, 1)
    }

    func testAgentFactoryReceivesSearchConfigurationSnapshot() async {
        let session = FakeSpeechSession()
        let agent = FakeConversationAgent(reply: "回答")
        var captured: ConversationAgentConfiguration?
        var dependencies = makeDependencies(session: session, agent: agent)
        dependencies.makeAgent = { configuration in
            captured = configuration
            return agent
        }
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()
        session.emit(.transcript("需要搜索"))
        session.emit(.finished)
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(captured?.model, "deepseek-v4-flash")
        XCTAssertEqual(captured?.enableSearch, true)
        XCTAssertEqual(captured?.bochaAPIKey, "bocha-key")
        XCTAssertFalse(captured?.systemPrompt.isEmpty ?? true)
    }

    func testStreamingDeltasAppearInOrderAndCompleteOnlyAfterVisibleTextCatchesUp() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("流式问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }

        agent.emit(.contentDelta("你"))
        agent.emit(.contentDelta("好"))
        agent.emit(.contentDelta("，世界"))
        await waitUntil { controller.assistantReply == "你好，世界" }
        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(controller.messages.last?.status, .pending)

        agent.complete(with: "你好，世界")
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.messages.last?.text, "你好，世界")
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testPartialFailureKeepsVisibleTextAndDoesNotCompleteMessage() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("会失败的问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("已有部分"))
        await waitUntil { controller.assistantReply == "已有部分" }

        agent.fail(TestFailure.agent)
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "已有部分")
        XCTAssertEqual(controller.messages.last?.text, "已有部分")
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertTrue(controller.lastError?.hasPrefix("回答中断，请重试") == true)
    }

    func testResetRejectsLateStreamingEvents() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("旧问题"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("旧"))
        await waitUntil { controller.assistantReply == "旧" }

        await controller.resetConversation()
        agent.emit(.contentDelta("迟到"))
        agent.complete(with: "旧迟到")
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.messages.isEmpty)
        XCTAssertTrue(controller.assistantReply.isEmpty)
    }

    func testIncompleteStreamAfterPartialTextPreservesPartialAndFails() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("未完整流"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("已显示"))
        await waitUntil { controller.assistantReply == "已显示" }

        agent.finishWithoutCompletion()
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "已显示")
        XCTAssertEqual(controller.messages.last?.status, .failed)
        XCTAssertTrue(controller.lastError?.contains("模型流未正常完成") == true)
    }

    func testWhitespaceOnlyCompletionFailsWithoutKeepingAssistantMessage() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空回答"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.complete(with: "  \n")
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.messages.map(\.text), ["空回答"])
        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.lastError, "AI 回复失败：模型返回了空回答")
    }

    func testInconsistentCompletedAnswerFailsWithoutOverwritingPartialText() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("不一致流"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("前缀"))
        await waitUntil { controller.assistantReply == "前缀" }

        agent.complete(with: "不同答案")
        await waitUntil { controller.state == .failed }

        XCTAssertEqual(controller.assistantReply, "前缀")
        XCTAssertEqual(controller.messages.last?.text, "前缀")
        XCTAssertTrue(controller.lastError?.contains("增量与完整回答不一致") == true)
    }

    func testMixedContentThenToolFailureDiscardsVisiblePseudoAnswer() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("混合响应"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("伪正文"))
        await waitUntil { controller.assistantReply == "伪正文" }

        agent.fail(ConversationAgentStreamError.discardPartial("混合 content/tool_call"))
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["混合响应"])
        XCTAssertFalse(controller.scene.elements.contains { element in
            guard case .flowingText(let text, _, _) = element.content else { return false }
            return text.contains("伪正文")
        })
    }

    func testCompletionReconcilesCombiningScalarSuffixWithoutCharacterIndexing() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("组合字符"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("e"))
        await waitUntil { controller.assistantReply == "e" }

        agent.complete(with: "e\u{301}")
        await waitUntil { controller.state == .completed }

        XCTAssertEqual(controller.assistantReply.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(controller.messages.last?.text.unicodeScalars.map(\.value), [0x65, 0x301])
    }

    func testWhitespaceDeltaThenFailureClearsVisibleAndDomainPartial() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空白失败"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("  \n"))
        await waitUntil { !controller.assistantReply.isEmpty }

        agent.fail(TestFailure.agent)
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["空白失败"])
    }

    func testWhitespaceDeltaThenEmptyCompletionClearsVisibleAndDomainPartial() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)

        await controller.toggleConversation()
        session.emit(.transcript("空白完成"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(" \n"))
        await waitUntil { !controller.assistantReply.isEmpty }

        agent.complete(with: " \n")
        await waitUntil { controller.state == .failed }

        XCTAssertTrue(controller.assistantReply.isEmpty)
        XCTAssertEqual(controller.messages.map(\.text), ["空白完成"])
        XCTAssertTrue(controller.lastError?.contains("空回答") == true)
    }

    func testNormalMotionDoesNotCompleteUntilTypewriterCatchesUp() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let sleeper = ManualSleeper()
        let dependencies = makeDependencies(
            session: session,
            agent: agent,
            sleep: { _ in try await sleeper.sleep() },
            reduceMotion: { false }
        )
        let controller = VoiceConversationController(dependencies: dependencies)
        let answer = String(repeating: "流", count: 40)

        await controller.toggleConversation()
        session.emit(.transcript("打字机追平"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(answer))
        agent.complete(with: answer)
        await waitUntil { !controller.assistantReply.isEmpty }

        XCTAssertEqual(controller.state, .streaming)
        XCTAssertLessThan(controller.assistantReply.count, answer.count)
        XCTAssertEqual(controller.messages.last?.status, .pending)

        for _ in 0..<20 where controller.state != .completed {
            let previousVisibleCount = controller.assistantReply.count
            sleeper.advance()
            await waitUntil {
                controller.state == .completed
                    || controller.assistantReply.count > previousVisibleCount
            }
        }
        await waitUntil { controller.state == .completed }
        XCTAssertEqual(controller.assistantReply, answer)
        XCTAssertEqual(controller.messages.last?.status, .completed)
    }

    func testReduceMotionFlushesWholeDeltaWithoutTypewriterFrames() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let controller = makeController(session: session, agent: agent)
        let answer = "中文👨‍👩‍👧‍👦e\u{301}\nEnglish"

        await controller.toggleConversation()
        session.emit(.transcript("减少动效"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta(answer))

        await waitUntil { controller.assistantReply == answer }
        XCTAssertEqual(controller.state, .streaming)
    }

    func testControllerUsesInjectedStreamingTextTickPolicy() async {
        let session = FakeSpeechSession()
        let agent = ControlledConversationAgent()
        let recorder = DurationRecorder()
        var dependencies = makeDependencies(
            session: session,
            agent: agent,
            sleep: { duration in
                recorder.record(duration)
                throw CancellationError()
            },
            reduceMotion: { false }
        )
        dependencies.streamingTextPolicy = TypewriterPolicy(tickIntervalMilliseconds: 77)
        let controller = VoiceConversationController(dependencies: dependencies)

        await controller.toggleConversation()
        session.emit(.transcript("节奏策略"))
        session.emit(.finished)
        await waitUntil { agent.isWaiting }
        agent.emit(.contentDelta("两字"))
        await waitUntil { recorder.value != nil }

        XCTAssertEqual(recorder.value, .milliseconds(77))
        XCTAssertEqual(controller.assistantReply, "两")
        XCTAssertEqual(controller.state, .streaming)
    }

    func testConversationHUDUsesDedicatedLargeFlowingTextViewport() {
        let scene = ConversationHUDMapper.makeScene(
            revision: 1,
            state: .streaming,
            transcript: "问题",
            assistantReply: "回答",
            audioLevel: 0,
            error: nil
        )
        let reply = scene.elements.first { $0.id == "assistant_reply" }

        XCTAssertEqual(reply?.frame.height, 0.61)
        XCTAssertGreaterThanOrEqual(reply?.frame.height ?? 0, 0.55)
        guard let content = reply?.content,
              case .flowingText(let text, let isStreaming, let footer) = content else {
            return XCTFail("应使用 AI 专用流式文本")
        }
        XCTAssertEqual(text, "回答")
        XCTAssertTrue(isStreaming)
        XCTAssertNil(footer)
    }

    private func makeController(
        session: FakeSpeechSession,
        agent: any ConversationAgent
    ) -> VoiceConversationController {
        VoiceConversationController(dependencies: makeDependencies(session: session, agent: agent))
    }

    private func makeDependencies(
        session: FakeSpeechSession,
        agent: any ConversationAgent,
        sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() },
        reduceMotion: @escaping () -> Bool = { true }
    ) -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            configuration: { .valid },
            makeSpeechSession: { _ in session },
            makeAgent: { _ in agent },
            requestMicrophonePermission: { true },
            now: { Date(timeIntervalSince1970: 100) },
            sleep: sleep,
            reduceMotion: reduceMotion
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

private extension AIConversationConfiguration {
    static let valid = Self(
        speechAPIKey: "speech-key",
        asrResourceID: "volc.seedasr.sauc.duration",
        asrLanguage: "zh-CN",
        hotwords: ["单绿眼镜"],
        handsFree: false,
        llmAPIKey: "llm-key",
        llmModel: "deepseek-v4-flash",
        enableSearch: true,
        bochaAPIKey: "bocha-key"
    )

    static let missingASR = Self(
        speechAPIKey: "",
        asrResourceID: "volc.seedasr.sauc.duration",
        asrLanguage: "zh-CN",
        hotwords: [],
        handsFree: false,
        llmAPIKey: "llm-key",
        llmModel: "deepseek-v4-flash",
        enableSearch: false,
        bochaAPIKey: ""
    )
}

private final class FakeSpeechSession: SpeechRecognitionSession {
    let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation

    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    init() {
        let (events, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func emit(_ event: SpeechRecognitionEvent) {
        continuation.yield(event)
    }

    func start() async throws { startCount += 1 }
    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}

private final class FakeConversationAgent: ConversationAgent, @unchecked Sendable {
    private let reply: String
    private let error: Error?
    private(set) var receivedTexts: [String] = []
    private(set) var clearCount = 0

    init(reply: String = "", error: Error? = nil) {
        self.reply = reply
        self.error = error
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        receivedTexts.append(userText)
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for character in reply {
                continuation.yield(.contentDelta(String(character)))
            }
            continuation.yield(.completed(reply))
            continuation.finish()
        }
    }

    func clearContext() async { clearCount += 1 }
}

private final class ControlledConversationAgent: ConversationAgent, @unchecked Sendable {
    private let toolName: String?
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation?
    private(set) var clearCount = 0
    private(set) var wasCancelled = false

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    init(toolName: String? = nil) {
        self.toolName = toolName
    }

    func stream(_ userText: String) async -> AsyncThrowingStream<ConversationAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            if let toolName { continuation.yield(.toolCall(toolName)) }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.lock.withLock {
                    self?.wasCancelled = true
                    self?.continuation = nil
                }
            }
        }
    }

    func complete(with text: String) {
        let continuation = lock.withLock { () -> AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(.completed(text))
        continuation?.finish()
    }

    func emit(_ event: ConversationAgentEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func fail(_ error: Error) {
        let continuation = lock.withLock { () -> AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish(throwing: error)
    }

    func finishWithoutCompletion() {
        let continuation = lock.withLock { () -> AsyncThrowingStream<ConversationAgentEvent, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    func clearContext() async { lock.withLock { clearCount += 1 } }
}

private final class MutableTime: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private final class ManualSleeper: @unchecked Sendable {
    private let ticks: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let (ticks, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.ticks = ticks
        self.continuation = continuation
    }

    func sleep() async throws {
        var iterator = ticks.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func advance() {
        continuation.yield(())
    }
}

private final class DurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Duration?

    var value: Duration? { lock.withLock { storage } }

    func record(_ duration: Duration) {
        lock.withLock { storage = duration }
    }
}

private enum TestFailure: LocalizedError {
    case agent

    var errorDescription: String? { "测试 Agent 失败" }
}
