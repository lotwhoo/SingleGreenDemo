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
        let userText = transcript.isEmpty ? "点击开始，说出你的问题" : transcript
        let voiceLevel = min(max(Double(audioLevel), 0), 1)
        let voiceIsActive = switch state {
        case .idle, .completed, .failed: false
        default: true
        }

        let elements = [
            HUDElement(
                id: "voice_activity",
                frame: NormalizedRect(x: 0.04, y: 0.06, width: 0.08, height: 0.20),
                content: .voiceWaveform(level: voiceLevel, isActive: voiceIsActive),
                opacity: voiceIsActive ? 0.92 : 0.68,
                semanticRole: .decorative
            ),
            HUDElement(
                id: "user_transcript",
                frame: NormalizedRect(x: 0.14, y: 0.06, width: 0.82, height: 0.20),
                content: .text(userText, .question),
                opacity: questionOpacity(state: state, hasTranscript: !transcript.isEmpty),
                alignment: .leading
            ),
            HUDElement(
                id: "conversation_divider_leading",
                frame: NormalizedRect(x: 0.04, y: 0.345, width: 0.30, height: 0.01),
                content: .rule(.horizontal, progress: 1),
                opacity: 0.52,
                alignment: .leading,
                semanticRole: .decorative
            ),
            HUDElement(
                id: "state_title",
                frame: NormalizedRect(x: 0.36, y: 0.295, width: 0.28, height: 0.11),
                content: .text(statusLabel(for: state), .caption),
                opacity: state == .failed ? 0.95 : 0.78,
                alignment: .center,
                semanticRole: .status
            ),
            HUDElement(
                id: "conversation_divider_trailing",
                frame: NormalizedRect(x: 0.66, y: 0.345, width: 0.30, height: 0.01),
                content: .rule(.horizontal, progress: 1),
                opacity: 0.52,
                alignment: .leading,
                semanticRole: .decorative
            ),
            mainContentElement(
                state: state,
                assistantReply: assistantReply,
                error: error
            )
        ]

        return HUDScene(
            sceneID: "ai_conversation",
            revision: revision,
            presentation: state == .failed ? .alert : (state == .completed ? .result : .focused),
            elements: elements
        )
    }

    private static func questionOpacity(
        state: VoiceConversationState,
        hasTranscript: Bool
    ) -> Double {
        guard hasTranscript else { return 0.56 }
        return switch state {
        case .connecting, .armed, .listening:
            0.88
        default:
            0.72
        }
    }

    private static func statusLabel(for state: VoiceConversationState) -> String {
        switch state {
        case .idle: "等待开始"
        case .connecting: "正在连接"
        case .armed, .listening: "正在聆听"
        case .recognizing: "正在识别"
        case .thinking: "正在思考"
        case .searching: "正在联网搜索"
        case .streaming: "正在回答"
        case .completed: "回答完成"
        case .failed: "对话失败"
        }
    }

    private static func mainContentElement(
        state: VoiceConversationState,
        assistantReply: String,
        error: String?
    ) -> HUDElement {
        let frame = NormalizedRect(x: 0.04, y: 0.43, width: 0.92, height: 0.53)
        if state == .recognizing || state == .thinking || state == .searching {
            return HUDElement(
                id: "assistant_reply",
                frame: frame,
                content: .activityIndicator,
                opacity: 1,
                alignment: .center
            )
        }
        if !assistantReply.isEmpty {
            return HUDElement(
                id: "assistant_reply",
                frame: frame,
                content: .styledFlowingText(
                    assistantReply,
                    isStreaming: state == .streaming,
                    footer: state == .failed ? "回答中断，请重试" : nil,
                    style: .answer
                ),
                opacity: 1,
                alignment: .leading
            )
        }
        if let error, !error.isEmpty {
            return HUDElement(
                id: "assistant_reply",
                frame: frame,
                content: .text(error, .detail),
                opacity: 0.95,
                alignment: .leading
            )
        }

        let placeholder: String
        switch state {
        case .connecting: placeholder = "正在准备语音输入"
        case .armed, .listening: placeholder = "请开始说话"
        default: placeholder = "AI 回答会显示在这里"
        }
        return HUDElement(
            id: "assistant_reply",
            frame: frame,
            content: .text(placeholder, .question),
            opacity: 0.42,
            alignment: .leading
        )
    }
}
