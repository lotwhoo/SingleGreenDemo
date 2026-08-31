import Foundation

public enum TeleprompterHUDMapper {
    public static func scene(for state: TeleprompterState, revision: Int) -> HUDScene {
        guard let script = state.script else {
            return HUDScene(
                sceneID: "teleprompter.asr",
                revision: revision,
                presentation: .focused,
                elements: [
                    HUDElement(
                        id: "title",
                        frame: NormalizedRect(x: 0.04, y: 0.10, width: 0.92, height: 0.18),
                        content: .text("语音提词器", .title),
                        opacity: 1,
                        alignment: .leading
                    ),
                    HUDElement(
                        id: "empty",
                        frame: NormalizedRect(x: 0.04, y: 0.34, width: 0.92, height: 0.30),
                        content: .text(state.userSafeError ?? "请先在手机端粘贴并载入稿件。", .detail),
                        opacity: 1,
                        alignment: .leading,
                        semanticRole: .status
                    ),
                    HUDElement(
                        id: "empty_hint",
                        frame: NormalizedRect(x: 0.04, y: 0.72, width: 0.92, height: 0.14),
                        content: .text("稿件仅在本机保存", .caption),
                        opacity: 0.84,
                        alignment: .leading,
                        semanticRole: .status
                    )
                ]
            )
        }

        let index = state.sentenceIndex
        let isCompleted = state.phase == .completed
        let previousText = index > 0 ? script.sentences[index - 1] : "尚未朗读"
        let previous = previousText + "\n"
        let currentSentence = script.sentences[index]
        let nextText = index + 1 < script.sentences.count
            ? script.sentences[index + 1]
            : "已到稿尾"
        let next = "\n" + nextText
        let bodyRuns: [HUDTextRun]
        if isCompleted {
            bodyRuns = [
                HUDTextRun(text: previous, opacity: 0.32),
                HUDTextRun(text: currentSentence + "\n", opacity: 0.32, isFocused: true),
                HUDTextRun(text: "已读完", opacity: 0.68)
            ].filter { !$0.text.isEmpty }
        } else {
            let sentence = currentSentence as NSString
            let offset = min(max(state.readingUTF16Offset, 0), sentence.length)
            let spoken = sentence.substring(to: offset)
            let unread = sentence.substring(from: offset)
            let spokenRun = spoken.isEmpty
                ? nil
                : HUDTextRun(text: spoken, opacity: 0.32)
            bodyRuns = [
                HUDTextRun(text: previous, opacity: 0.32),
                spokenRun,
                HUDTextRun(text: unread, opacity: 1, isFocused: true),
                HUDTextRun(text: next, opacity: 0.68)
            ].compactMap { $0 }.filter { !$0.text.isEmpty }
        }
        let status = switch state.phase {
        case .ready: "按 ↑ 开始语音跟随"
        case .preparing: "正在准备语音识别…"
        case .listening: "语音跟随中 · ↑ 暂停"
        case .paused: "已暂停 · ↑ 继续"
        case .manualFallback: state.userSafeError ?? "手动模式 · ← / → 调整"
        case .completed: "稿件已读完 · ↑ 重新开始"
        }

        return HUDScene(
            sceneID: "teleprompter.asr",
            revision: revision,
            presentation: .focused,
            elements: [
                HUDElement(
                    id: "teleprompter_header",
                    frame: NormalizedRect(x: 0.03, y: 0.02, width: 0.94, height: 0.12),
                    content: .text(
                        "提词  \(index + 1)/\(script.sentences.count) · \(status)",
                        .caption
                    ),
                    opacity: 1,
                    alignment: .leading,
                    semanticRole: .status
                ),
                HUDElement(
                    id: "teleprompter_body",
                    frame: NormalizedRect(x: 0.03, y: 0.17, width: 0.94, height: 0.80),
                    content: .styledFlowingTextRuns(
                        bodyRuns,
                        isStreaming: false,
                        footer: nil,
                        style: .detail
                    ),
                    opacity: 1,
                    alignment: .leading
                )
            ]
        )
    }
}
