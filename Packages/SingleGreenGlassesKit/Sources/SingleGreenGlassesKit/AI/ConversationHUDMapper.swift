import Foundation

public enum VoiceConversationState: String, Equatable, Sendable {
    case idle
    case connecting
    case armed
    case listening
    case recognizing
    case thinking
    case searching
    case streaming
    case completed
    case failed

    public var allowsPrimaryAction: Bool {
        self == .idle || self == .failed || self == .completed || self == .armed || self == .listening || self == .thinking || self == .searching || self == .streaming
    }

    public var displayName: String {
        switch self {
        case .idle: "AI 对话待命"
        case .connecting: "正在连接语音识别"
        case .armed: "本地聆听中"
        case .listening: "正在听你说话"
        case .recognizing: "正在整理问题"
        case .thinking: "AI 正在思考"
        case .searching: "AI 正在联网搜索"
        case .streaming: "AI 正在回答"
        case .completed: "AI 回答完成"
        case .failed: "AI 对话失败"
        }
    }

    public var systemImage: String {
        switch self {
        case .idle: "waveform.circle"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .armed: "ear.and.waveform"
        case .listening: "waveform"
        case .recognizing: "text.viewfinder"
        case .thinking: "ellipsis.bubble"
        case .searching: "globe"
        case .streaming: "text.bubble"
        case .completed: "checkmark.bubble"
        case .failed: "exclamationmark.triangle"
        }
    }
}

public enum ConversationHUDMapper {
    public static func makeScene(
        revision: Int,
        state: VoiceConversationState,
        transcript: String,
        assistantReply: String,
        audioLevel: Float,
        error: String?
    ) -> HUDScene {
        let userText = transcript.isEmpty ? "点击开始，说出你的问题" : "你：\(transcript)"
        let assistantText: String
        let interruptionFooter: String?
        if !assistantReply.isEmpty {
            assistantText = assistantReply
            interruptionFooter = state == .failed ? "回答中断，请重试" : nil
        } else if let error, !error.isEmpty {
            assistantText = error
            interruptionFooter = nil
        } else if state == .searching {
            assistantText = "AI 正在联网搜索…"
            interruptionFooter = nil
        } else if state == .thinking {
            assistantText = "AI 正在思考…"
            interruptionFooter = nil
        } else {
            assistantText = "AI 回答会显示在这里"
            interruptionFooter = nil
        }

        var elements = [
            HUDElement(id: "state_symbol", frame: NormalizedRect(x: 0.08, y: 0.05, width: 0.08, height: 0.08), content: .symbol(state.systemImage)),
            HUDElement(id: "state_title", frame: NormalizedRect(x: 0.19, y: 0.04, width: 0.73, height: 0.10), content: .text(state.displayName, .title)),
            HUDElement(id: "user_transcript", frame: NormalizedRect(x: 0.08, y: 0.20, width: 0.84, height: 0.10), content: .text(userText, .detail)),
            HUDElement(
                id: "assistant_reply",
                frame: NormalizedRect(x: 0.08, y: 0.35, width: 0.84, height: 0.61),
                content: .flowingText(
                    assistantText,
                    isStreaming: state == .streaming,
                    footer: interruptionFooter
                )
            )
        ]
        if state == .armed || state == .listening {
            elements.append(HUDElement(id: "audio_level", frame: NormalizedRect(x: 0.25, y: 0.32, width: 0.50, height: 0.02), content: .progress(Double(audioLevel))))
        }

        return HUDScene(
            sceneID: "ai_conversation",
            revision: revision,
            presentation: state == .failed ? .alert : (state == .completed ? .result : .focused),
            elements: elements
        )
    }
}
