import Foundation
import VoiceChatDomain

enum ConversationLifecycleProjection {
    static func transcript(liveText: String, conversation: ConversationState) -> String {
        if !liveText.trimmed.isEmpty { return liveText.trimmed }
        return conversation.messages.last(where: { $0.isUser })?.text ?? ""
    }

    static func assistantReply(displayedReply: String, conversation: ConversationState) -> String {
        if !displayedReply.isEmpty { return displayedReply }
        return conversation.messages.last(where: { !$0.isUser && $0.status == .completed })?.text ?? ""
    }

    static func voiceState(
        conversation: ConversationState,
        assistantReply: String,
        error: String?
    ) -> VoiceConversationState {
        switch conversation.inputState {
        case .preparing: return .connecting
        case .armed: return .armed
        case .recording: return .listening
        case .finalizing: return .recognizing
        case .failed: return .failed
        case .idle:
            if error != nil { return .failed }
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

    static func makeSnapshot(
        revision: Int,
        state: VoiceConversationState,
        transcript: String,
        assistantReply: String,
        audioLevel: Float,
        error: String?
    ) -> ExperienceSnapshot {
        let primaryActionTitle: String
        switch state {
        case .idle, .failed, .completed: primaryActionTitle = "开始对话"
        case .armed: primaryActionTitle = "停止聆听"
        case .listening: primaryActionTitle = "结束说话"
        case .connecting: primaryActionTitle = "连接语音识别"
        case .recognizing: primaryActionTitle = "整理识别结果"
        case .thinking, .searching, .streaming: primaryActionTitle = "打断并开始新对话"
        }

        let primaryActionSystemImage: String
        switch state {
        case .armed, .listening: primaryActionSystemImage = "stop.fill"
        case .connecting, .recognizing, .thinking, .searching, .streaming:
            primaryActionSystemImage = "ellipsis"
        case .completed: primaryActionSystemImage = "checkmark.circle.fill"
        default: primaryActionSystemImage = "waveform"
        }

        let statusDetail: String
        if let error { statusDetail = error }
        else if !assistantReply.isEmpty { statusDetail = assistantReply }
        else if !transcript.isEmpty { statusDetail = transcript }
        else { statusDetail = "语音识别 → 多轮 Agent → 按需联网搜索" }

        return ExperienceSnapshot(
            scene: ConversationHUDMapper.makeScene(
                revision: revision,
                state: state,
                transcript: transcript,
                assistantReply: assistantReply,
                audioLevel: audioLevel,
                error: error
            ),
            primaryActionTitle: primaryActionTitle,
            eventDescription: state.rawValue,
            controlState: ExperienceControlState(
                statusTitle: state.displayName,
                statusDetail: statusDetail,
                errorMessage: error,
                primaryActionSystemImage: primaryActionSystemImage,
                allowsPrimaryAction: state.allowsPrimaryAction
            )
        )
    }
}
