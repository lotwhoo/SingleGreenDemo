import Foundation

enum VoiceConversationState: String, Equatable, Sendable {
    case idle
    case connecting
    case listening
    case recognizing
    case thinking
    case searching
    case completed
    case failed

    var allowsPrimaryAction: Bool {
        self == .idle || self == .failed || self == .completed || self == .listening || self == .thinking || self == .searching
    }

    var displayName: String {
        switch self {
        case .idle: "AI 对话待命"
        case .connecting: "正在连接语音识别"
        case .listening: "正在听你说话"
        case .recognizing: "正在整理问题"
        case .thinking: "AI 正在思考"
        case .searching: "AI 正在联网搜索"
        case .completed: "AI 回答完成"
        case .failed: "AI 对话失败"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "waveform.circle"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .listening: "waveform"
        case .recognizing: "text.viewfinder"
        case .thinking: "ellipsis.bubble"
        case .searching: "globe"
        case .completed: "checkmark.bubble"
        case .failed: "exclamationmark.triangle"
        }
    }
}

enum ConversationHUDMapper {
    static func makeScene(
        revision: Int,
        state: VoiceConversationState,
        transcript: String,
        assistantReply: String,
        audioLevel: Float,
        error: String?
    ) -> HUDScene {
        let userText = transcript.isEmpty ? "点击开始，说出你的问题" : "你：\(transcript)"
        let assistantText: String
        if let error, !error.isEmpty {
            assistantText = error
        } else if !assistantReply.isEmpty {
            assistantText = "AI：\(assistantReply)"
        } else if state == .searching {
            assistantText = "AI 正在联网搜索…"
        } else if state == .thinking {
            assistantText = "AI 正在思考…"
        } else {
            assistantText = "AI 回答会显示在这里"
        }

        var elements = [
            HUDElement(id: "state_symbol", frame: NormalizedRect(x: 0.44, y: 0.06, width: 0.12, height: 0.10), content: .symbol(state.systemImage)),
            HUDElement(id: "state_title", frame: NormalizedRect(x: 0.15, y: 0.18, width: 0.70, height: 0.10), content: .text(state.displayName, .title)),
            HUDElement(id: "user_transcript", frame: NormalizedRect(x: 0.10, y: 0.32, width: 0.80, height: 0.20), content: .text(userText, .detail)),
            HUDElement(id: "assistant_reply", frame: NormalizedRect(x: 0.10, y: 0.56, width: 0.80, height: 0.28), content: .text(assistantText, .detail))
        ]
        if state == .listening {
            elements.append(HUDElement(id: "audio_level", frame: NormalizedRect(x: 0.25, y: 0.88, width: 0.50, height: 0.04), content: .progress(Double(audioLevel))))
        }

        return HUDScene(
            sceneID: "ai_conversation",
            revision: revision,
            presentation: state == .failed ? .alert : (state == .completed ? .result : .focused),
            elements: elements
        )
    }
}
