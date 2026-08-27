import Foundation
import StreamingTextKit
import VoiceChatDomain

/// AI 对话用例编排。只依赖可替换的端口，不直接创建 ASR、LLM、权限或时钟实现。
@MainActor
final class VoiceConversationController: ObservableObject {
    @Published private(set) var conversation = ConversationState()
    @Published private(set) var liveText = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var scene: HUDScene
    @Published private(set) var revision = 0

    private let dependencies: VoiceConversationDependencies
    private var asrSession: (any SpeechRecognitionSession)?
    private var asrEventsTask: Task<Void, Never>?
    private var replyTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    private var replyGeneration = 0
    private var typewriterBuffer: TypewriterTextBuffer
    private var displayedReply = ""
    private var upstreamCompletedReply: (id: UUID, generation: Int)?
    private var didHandleFinal = false
    private var lastSoundTime: Date
    private let silenceThreshold: Float
    private let silenceTimeout: TimeInterval

    private var agent: (any ConversationAgent)?
    private var agentConfiguration: ConversationAgentConfiguration?

    private let systemPrompt = "你是单绿眼镜中的友好语音助手。请优先用简洁、自然的中文回答，一般不超过 200 字。遇到需要最新、实时或外部信息的问题时使用联网搜索工具，并基于搜索结果回答。"

    convenience init(settings: AISettings) {
        self.init(dependencies: .live(settings: settings))
    }

    init(
        dependencies: VoiceConversationDependencies,
        silenceThreshold: Float = 0.03,
        silenceTimeout: TimeInterval = 1.5
    ) {
        self.dependencies = dependencies
        self.silenceThreshold = silenceThreshold
        self.silenceTimeout = silenceTimeout
        self.lastSoundTime = dependencies.now()
        self.typewriterBuffer = TypewriterTextBuffer(policy: dependencies.streamingTextPolicy)
        scene = ConversationHUDMapper.makeScene(
            revision: 0,
            state: .idle,
            transcript: "",
            assistantReply: "",
            audioLevel: 0,
            error: nil
        )
    }

    var messages: [ChatMessage] { conversation.messages }

    var transcript: String {
        if !liveText.trimmed.isEmpty { return liveText.trimmed }
        return conversation.messages.last(where: { $0.isUser })?.text ?? ""
    }

    var assistantReply: String {
        if !displayedReply.isEmpty { return displayedReply }
        return conversation.messages.last(where: { !$0.isUser && $0.status == .completed })?.text ?? ""
    }

    var state: VoiceConversationState {
        switch conversation.inputState {
        case .preparing: return .connecting
        case .recording: return .listening
        case .finalizing: return .recognizing
        case .failed: return .failed
        case .idle:
            if lastError != nil { return .failed }
            switch conversation.replyState {
            case .requesting: return .thinking
            case .searching: return .searching
            case .streaming: return .streaming
            case .completed: return .completed
            case .failed: return .failed
            case .idle, .cancelled:
                return assistantReply.isEmpty ? .idle : .completed
            }
        }
    }

    var primaryActionTitle: String {
        switch state {
        case .idle, .failed, .completed: "开始对话"
        case .listening: "结束说话"
        case .connecting: "连接语音识别"
        case .recognizing: "整理识别结果"
        case .thinking, .searching, .streaming: "打断并开始新对话"
        }
    }

    var primaryActionSystemImage: String {
        switch state {
        case .listening: "stop.fill"
        case .connecting, .recognizing, .thinking, .searching, .streaming: "ellipsis"
        case .completed: "checkmark.circle.fill"
        default: "waveform"
        }
    }

    var allowsPrimaryAction: Bool { state.allowsPrimaryAction }
    var lastEventDescription: String { state.rawValue }

    func toggleConversation() async {
        switch state {
        case .idle, .failed, .completed, .thinking, .searching, .streaming:
            await startListening()
        case .listening:
            await stopRecognition()
        case .connecting, .recognizing:
            break
        }
    }

    func resetConversation() async {
        await cancelInput()
        await invalidatePendingReply()
        if let agent { await agent.clearContext() }
        agent = nil
        agentConfiguration = nil
        conversation = ConversationState()
        typewriterBuffer.reset()
        displayedReply = ""
        upstreamCompletedReply = nil
        liveText = ""
        audioLevel = 0
        lastError = nil
        refreshScene()
    }

    private func startListening() async {
        guard state.allowsPrimaryAction, state != .listening else { return }
        let configuration = dependencies.configuration()
        guard configuration.isASRConfigured else {
            await failInput("请先在设置中填写豆包 ASR API Key 和资源 ID。")
            return
        }

        await cancelInput()
        await invalidatePendingReply()
        lastError = nil
        liveText = ""
        audioLevel = 0
        didHandleFinal = false
        lastSoundTime = dependencies.now()
        conversation.inputState = .preparing
        refreshScene()

        guard await dependencies.requestMicrophonePermission() else {
            await failInput("未获得麦克风权限，请在系统设置中允许访问。")
            return
        }

        let session = dependencies.makeSpeechSession(.init(
            apiKey: configuration.speechAPIKey.trimmed,
            resourceID: configuration.asrResourceID.trimmed,
            language: configuration.asrLanguage,
            hotwords: configuration.hotwords
        ))
        asrSession = session
        observe(session)

        do {
            try await session.start()
            guard isActive(session) else { return }
            conversation.inputState = .recording
            if configuration.handsFree { startVAD() }
            refreshScene()
        } catch {
            await failInput("语音识别启动失败：\(error.localizedDescription)")
        }
    }

    private func stopRecognition() async {
        guard conversation.inputState == .recording, let asrSession else { return }
        conversation.inputState = .finalizing
        vadTask?.cancel()
        vadTask = nil
        refreshScene()
        await asrSession.finish()
    }

    private func startVAD() {
        vadTask?.cancel()
        vadTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.dependencies.sleep(.milliseconds(250))
                } catch {
                    return
                }
                guard self.conversation.inputState == .recording else { return }
                if self.dependencies.now().timeIntervalSince(self.lastSoundTime) > self.silenceTimeout {
                    await self.stopRecognition()
                    return
                }
            }
        }
    }

    private func observe(_ session: any SpeechRecognitionSession) {
        asrEventsTask?.cancel()
        asrEventsTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, from: session)
            }
        }
    }

    private func handle(
        _ event: SpeechRecognitionEvent,
        from session: any SpeechRecognitionSession
    ) async {
        guard isActive(session) else { return }
        switch event {
        case .transcript(let text):
            let normalized = text.trimmed
            if !normalized.isEmpty { liveText = normalized }
            refreshScene()

        case .utterance:
            // 定型句只适合分段字幕；最终问题始终以累计 transcript 为准。
            break

        case .level(let value):
            audioLevel = max(0, min(value, 1))
            if value > silenceThreshold { lastSoundTime = dependencies.now() }
            refreshScene()

        case .finished:
            guard !didHandleFinal else { return }
            didHandleFinal = true
            await finishASRAndRequestReply()

        case .failed(let message):
            await failInput("语音识别失败：\(message)")
        }
    }

    private func finishASRAndRequestReply() async {
        conversation.inputState = .idle
        audioLevel = 0
        vadTask?.cancel()
        vadTask = nil
        asrEventsTask?.cancel()
        asrEventsTask = nil
        asrSession = nil

        let finalText = liveText.trimmed
        liveText = ""
        guard !finalText.isEmpty else {
            lastError = "没有识别到有效语音，请靠近手机后重试。"
            refreshScene()
            return
        }

        conversation.appendUser(finalText)
        await invalidatePendingReply()
        refreshScene()
        replyTask = Task { [weak self] in
            await self?.requestReply(userText: finalText)
        }
    }

    private func requestReply(userText: String) async {
        let configuration = dependencies.configuration()
        guard configuration.isLLMConfigured else {
            failReplyConfiguration("请先在设置中填写 DeepSeek API Key 和模型。")
            return
        }
        guard configuration.isSearchConfigured else {
            failReplyConfiguration("已开启联网搜索，请先填写博查搜索 API Key。")
            return
        }

        replyGeneration += 1
        let generation = replyGeneration
        let replyID = conversation.beginReply()
        typewriterBuffer.reset()
        displayedReply = ""
        upstreamCompletedReply = nil
        lastError = nil
        refreshScene()

        let currentAgentConfiguration = ConversationAgentConfiguration(
            apiKey: configuration.llmAPIKey.trimmed,
            model: configuration.llmModel.trimmed,
            enableSearch: configuration.enableSearch,
            bochaAPIKey: configuration.bochaAPIKey.trimmed,
            systemPrompt: systemPrompt
        )
        if agent == nil || agentConfiguration != currentAgentConfiguration {
            agent = dependencies.makeAgent(currentAgentConfiguration)
            agentConfiguration = currentAgentConfiguration
        }
        guard let agent else { return }

        do {
            let events = await agent.stream(userText)
            var didReceiveCompletionEvent = false
            for try await event in events {
                try Task.checkCancellation()
                guard generation == replyGeneration else { return }
                switch event {
                case .toolCall(let toolName):
                    guard toolName == "web_search" else { continue }
                    markReplySearching(id: replyID, generation: generation)

                case .contentDelta(let delta):
                    receiveReplyDelta(delta, id: replyID, generation: generation)

                case .completed(let answer):
                    try receiveReplyCompletion(answer, id: replyID, generation: generation)
                    didReceiveCompletionEvent = true
                }
            }
            guard generation == replyGeneration else { return }
            if !didReceiveCompletionEvent {
                throw ConversationControllerError.incompleteStream
            }
            replyTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == replyGeneration else { return }
            typingTask?.cancel()
            typingTask = nil
            upstreamCompletedReply = nil
            let mustDiscardPartial = (error as? ConversationAgentStreamError)?.shouldDiscardPartial == true
            let hasPartialReply = !mustDiscardPartial && !typewriterBuffer.targetText.trimmed.isEmpty
            if mustDiscardPartial || !hasPartialReply {
                typewriterBuffer.reset()
                displayedReply = ""
            } else {
                _ = typewriterBuffer.flush()
                displayedReply = typewriterBuffer.visibleText
            }
            let message = hasPartialReply
                ? "回答中断，请重试：\(error.localizedDescription)"
                : "AI 回复失败：\(error.localizedDescription)"
            _ = conversation.failReply(
                id: replyID,
                message: message,
                preservingPartial: hasPartialReply
            )
            lastError = message
            replyTask = nil
            refreshScene()
        }
    }

    private func failReplyConfiguration(_ message: String) {
        lastError = message
        conversation.inputState = .idle
        refreshScene()
    }

    private func markReplySearching(id: UUID, generation: Int) {
        guard replyGeneration == generation else { return }
        conversation.markSearching(id: id)
        refreshScene()
    }

    private func receiveReplyDelta(_ delta: String, id: UUID, generation: Int) {
        guard generation == replyGeneration, !delta.isEmpty,
              conversation.appendReplyDelta(id: id, delta: delta) else { return }
        typewriterBuffer.append(delta)
        startTyping(id: id, generation: generation)
    }

    private func receiveReplyCompletion(_ answer: String, id: UUID, generation: Int) throws {
        guard generation == replyGeneration, conversation.activeReplyID == id else { return }
        guard !answer.trimmed.isEmpty else { throw ConversationControllerError.emptyReply }

        let accumulated = conversation.messages.first(where: { $0.id == id })?.text ?? ""
        if accumulated != answer {
            guard let suffix = StreamingTextReconciler.suffix(in: answer, after: accumulated) else {
                throw ConversationControllerError.inconsistentStream
            }
            receiveReplyDelta(suffix, id: id, generation: generation)
        }
        upstreamCompletedReply = (id, generation)
        startTyping(id: id, generation: generation)
    }

    private func startTyping(id: UUID, generation: Int) {
        guard typingTask == nil else { return }
        typingTask = Task { [weak self] in
            await self?.runTyping(id: id, generation: generation)
        }
    }

    private func runTyping(id: UUID, generation: Int) async {
        while !Task.isCancelled {
            guard generation == replyGeneration, conversation.activeReplyID == id else { return }

            let changed: Bool
            if dependencies.reduceMotion() {
                changed = typewriterBuffer.flush()
            } else {
                changed = typewriterBuffer.advance(maxCharacters: typewriterBuffer.suggestedBatchSize())
            }
            if changed {
                displayedReply = typewriterBuffer.visibleText
                refreshScene()
            }

            if typewriterBuffer.isCaughtUp,
               upstreamCompletedReply?.id == id,
               upstreamCompletedReply?.generation == generation {
                guard conversation.completeReply(id: id) else { return }
                upstreamCompletedReply = nil
                typingTask = nil
                lastError = nil
                refreshScene()
                return
            }

            do {
                try await dependencies.sleep(.milliseconds(
                    dependencies.streamingTextPolicy.tickIntervalMilliseconds
                ))
            } catch {
                return
            }
        }
    }

    private func invalidatePendingReply() async {
        replyGeneration += 1
        _ = conversation.cancelActiveReply()
        upstreamCompletedReply = nil
        typewriterBuffer.reset()
        displayedReply = ""
        let activeTypingTask = typingTask
        typingTask = nil
        activeTypingTask?.cancel()
        let task = replyTask
        replyTask = nil
        task?.cancel()
        await task?.value
    }

    private func failInput(_ message: String) async {
        asrEventsTask?.cancel()
        asrEventsTask = nil
        vadTask?.cancel()
        vadTask = nil
        let session = asrSession
        asrSession = nil
        await session?.cancel()
        audioLevel = 0
        liveText = ""
        lastError = message
        conversation.inputState = .failed(message)
        refreshScene()
    }

    private func cancelInput() async {
        asrEventsTask?.cancel()
        asrEventsTask = nil
        vadTask?.cancel()
        vadTask = nil
        let session = asrSession
        asrSession = nil
        await session?.cancel()
        audioLevel = 0
        conversation.inputState = .idle
    }

    private func isActive(_ session: any SpeechRecognitionSession) -> Bool {
        guard let asrSession else { return false }
        return asrSession === session
    }

    private func refreshScene() {
        revision += 1
        scene = ConversationHUDMapper.makeScene(
            revision: revision,
            state: state,
            transcript: transcript,
            assistantReply: assistantReply,
            audioLevel: audioLevel,
            error: lastError
        )
    }
}

private enum ConversationControllerError: LocalizedError {
    case emptyReply
    case incompleteStream
    case inconsistentStream

    var errorDescription: String? {
        switch self {
        case .emptyReply: "模型返回了空回答"
        case .incompleteStream: "模型流未正常完成"
        case .inconsistentStream: "模型流的增量与完整回答不一致"
        }
    }
}
