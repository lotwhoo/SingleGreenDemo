import SingleGreenGlassesKit

extension ConversationPresentationCopy {
    static let singleGreenDemo = Self(
        voiceActivatedUnavailable: "本地语音检测暂不可用，请切换到手动语音输入。",
        microphonePermissionDenied: "未获得麦克风权限，请在系统设置中允许访问。",
        speechRecognitionUnavailable: "语音识别暂时不可用，请稍后重试。",
        noSpeech: "没有识别到有效语音，请靠近手机后重试。",
        replyPreparationUnavailable: "暂时无法准备 AI 回答服务，请稍后重试。",
        emptyReply: "AI 服务返回了空回答。",
        inconsistentReplyStream: "AI 回答流的增量与完整内容不一致。",
        incompleteReplyStream: "AI 回答流未正常完成。",
        unexpectedReplyFailure: "回答流程暂时中断。",
        interruptedReplyPrefix: "回答中断，请重试：",
        failedReplyPrefix: "AI 回复失败：",
        contextCommitFailed: "回答已显示，但对话上下文保存失败，请重试。"
    )
}
