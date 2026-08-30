import Foundation

public enum TextAdventureHUDMapper {
    public static func scene(
        for state: TextAdventureState,
        visibleNarrative: String,
        revision: Int
    ) -> HUDScene {
        switch state.phase {
        case .idle:
            return HUDScene(
                sceneID: "text_adventure.green_signal",
                revision: revision,
                presentation: .focused,
                elements: [
                    HUDElement(
                        id: "title",
                        frame: NormalizedRect(x: 0.04, y: 0.08, width: 0.92, height: 0.22),
                        content: .text("异闻信号", .title),
                        opacity: 1,
                        alignment: .leading
                    ),
                    HUDElement(
                        id: "intro",
                        frame: NormalizedRect(x: 0.04, y: 0.32, width: 0.92, height: 0.28),
                        content: .text(
                            state.userSafeError ?? "每局先寻找新灵感，再生成完整故事框架。",
                            .detail
                        ),
                        opacity: 1,
                        alignment: .leading
                    ),
                    HUDElement(
                        id: "start",
                        frame: NormalizedRect(x: 0.04, y: 0.68, width: 0.92, height: 0.18),
                        content: .text("按 → 开始", .caption),
                        opacity: 1,
                        alignment: .leading,
                        semanticRole: .status
                    )
                ]
            )
        case .searchingInspiration:
            return preparationScene(
                body: "正在搜索近期热门题材…",
                detail: "仅提取抽象主题，不保留标题、人物或原文。",
                revision: revision
            )
        case .generatingFramework:
            return preparationScene(
                body: "正在生成本局故事框架…",
                detail: "背景、关系、谜题与开场将在本局保持不变。",
                revision: revision
            )
        case .playing, .ending:
            guard let checkpoint = state.checkpoint else {
                return scene(for: TextAdventureState(), visibleNarrative: "", revision: revision)
            }
            return contentScene(
                state: state,
                checkpoint: checkpoint,
                visibleNarrative: visibleNarrative,
                revision: revision
            )
        }
    }

    private static func preparationScene(
        body: String,
        detail: String,
        revision: Int
    ) -> HUDScene {
        HUDScene(
            sceneID: "text_adventure.green_signal",
            revision: revision,
            presentation: .focused,
            elements: [
                HUDElement(
                    id: "title",
                    frame: NormalizedRect(x: 0.04, y: 0.08, width: 0.92, height: 0.20),
                    content: .text("异闻信号", .title),
                    opacity: 1,
                    alignment: .leading
                ),
                HUDElement(
                    id: "preparation",
                    frame: NormalizedRect(x: 0.04, y: 0.34, width: 0.92, height: 0.20),
                    content: .text(body, .detail),
                    opacity: 1,
                    alignment: .leading,
                    semanticRole: .status
                ),
                HUDElement(
                    id: "preparation_detail",
                    frame: NormalizedRect(x: 0.04, y: 0.61, width: 0.92, height: 0.24),
                    content: .text(detail, .caption),
                    opacity: 0.86,
                    alignment: .leading
                )
            ]
        )
    }

    private static func contentScene(
        state: TextAdventureState,
        checkpoint: TextAdventureCheckpoint,
        visibleNarrative: String,
        revision: Int
    ) -> HUDScene {
        let title = "异闻  " + String(checkpoint.turn)
            + "/" + String(TextAdventureLimits.maximumTurn)
        let completeNarrative = checkpoint.narrative
        let isTypewriting = state.overlay == .story && visibleNarrative != completeNarrative
        let body: String
        let footer: String?
        switch state.overlay {
        case .story:
            body = visibleNarrative
            if state.isRequestInFlight {
                footer = "正在接收下一段信号…"
            } else if isTypewriting {
                footer = "正在显示信号…"
            } else if checkpoint.outcome == .ended {
                footer = "故事结束 · 按 → 重新开始"
            } else if let error = state.userSafeError {
                footer = error
            } else {
                footer = "← \(checkpoint.choiceA ?? "")    \(checkpoint.choiceB ?? "") →"
            }
        case .recap:
            body = "上回：\(checkpoint.recap)"
            footer = "← A   ·   B →"
        case .status:
            let inventory = checkpoint.status.inventory.isEmpty
                ? "无"
                : checkpoint.status.inventory.joined(separator: "、")
            body = "体力 \(checkpoint.status.energy)/3  信号 \(checkpoint.status.signal)/3\n物品 \(inventory)"
            footer = "提示：\(checkpoint.hint)"
        }

        return HUDScene(
            sceneID: "text_adventure.green_signal",
            revision: revision,
            presentation: checkpoint.outcome == .ended ? .result : .focused,
            elements: [
                HUDElement(
                    id: "game_header",
                    frame: NormalizedRect(x: 0.03, y: 0.03, width: 0.94, height: 0.16),
                    content: .text(title, .caption),
                    opacity: 1,
                    alignment: .leading,
                    semanticRole: .status
                ),
                HUDElement(
                    id: "game_body",
                    frame: NormalizedRect(x: 0.03, y: 0.20, width: 0.94, height: 0.58),
                    content: .styledFlowingText(
                        body,
                        isStreaming: state.isRequestInFlight || isTypewriting,
                        footer: nil,
                        style: .detail
                    ),
                    opacity: 1,
                    alignment: .leading
                ),
                HUDElement(
                    id: "game_footer",
                    frame: NormalizedRect(x: 0.03, y: 0.80, width: 0.94, height: 0.17),
                    content: .text(footer ?? "", .caption),
                    opacity: 1,
                    alignment: .leading,
                    semanticRole: .status
                )
            ]
        )
    }
}
