import XCTest
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

    private func makeController(
        session: FakeSpeechSession,
        agent: any ConversationAgent
    ) -> VoiceConversationController {
        VoiceConversationController(dependencies: makeDependencies(session: session, agent: agent))
    }

    private func makeDependencies(
        session: FakeSpeechSession,
        agent: any ConversationAgent
    ) -> VoiceConversationDependencies {
        VoiceConversationDependencies(
            configuration: { .valid },
            makeSpeechSession: { _ in session },
            makeAgent: { _ in agent },
            requestMicrophonePermission: { true },
            now: { Date(timeIntervalSince1970: 100) },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
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

    func send(
        _ userText: String,
        onToolCall: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        receivedTexts.append(userText)
        if let error { throw error }
        return reply
    }

    func clearContext() async { clearCount += 1 }
}

private final class ControlledConversationAgent: ConversationAgent, @unchecked Sendable {
    private let toolName: String?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var clearCount = 0
    private(set) var wasCancelled = false

    var isWaiting: Bool {
        lock.withLock { continuation != nil }
    }

    init(toolName: String? = nil) {
        self.toolName = toolName
    }

    func send(
        _ userText: String,
        onToolCall: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        if let toolName { await onToolCall?(toolName) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
                wasCancelled = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func complete(with text: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: text)
    }

    func clearContext() async { lock.withLock { clearCount += 1 } }
}

private final class MutableTime: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private enum TestFailure: LocalizedError {
    case agent

    var errorDescription: String? { "测试 Agent 失败" }
}
