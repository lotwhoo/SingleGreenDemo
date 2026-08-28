import Foundation

@MainActor
public final class CaptionExperience: ExperienceSession {
    public let descriptor = ExperienceDescriptor(
        kind: .caption,
        displayName: "字幕 / 提词",
        detail: "体验场景 · 本地样例",
        systemImageName: "captions.bubble",
        actions: [
            BuiltInExperienceActions.primary(
                event: .tap,
                icon: "text.bubble.fill",
                accessibilityLabel: "播放或暂停字幕"
            )
        ] + BuiltInExperienceActions.standardSecondary
    )
    private let lines = [
        "我们先确认今天的核心目标",
        "再开始下一阶段测试",
        "所有内容均为本地模拟数据"
    ]

    private var index = 0
    private var isPlaying = false
    private var revision = 0

    public init() {}

    public var primaryActionTitle: String {
        isPlaying ? "暂停字幕" : "播放字幕"
    }

    public var scene: HUDScene {
        let nextIndex = min(index + 1, lines.count - 1)
        return HUDScene(
            sceneID: "caption_\(index)",
            revision: revision,
            presentation: .focused,
            elements: [
                HUDElement(
                    id: "current",
                    frame: NormalizedRect(x: 0.05, y: 0.26, width: 0.90, height: 0.24),
                    content: .text(lines[index], .title)
                ),
                HUDElement(
                    id: "next",
                    frame: NormalizedRect(x: 0.08, y: 0.54, width: 0.84, height: 0.22),
                    content: .text(index == nextIndex ? "本地样例结束" : lines[nextIndex], .detail)
                ),
                HUDElement(
                    id: "playback",
                    frame: NormalizedRect(x: 0.44, y: 0.82, width: 0.12, height: 0.12),
                    content: .symbol(isPlaying ? "pause.fill" : "play.fill")
                )
            ]
        )
    }

    public func handle(_ event: DemoEvent) async {
        let previousIndex = index
        let wasPlaying = isPlaying
        switch event {
        case .tap:
            isPlaying.toggle()
        case .swipeUp:
            index = max(0, index - 1)
        case .swipeDown:
            index = min(lines.count - 1, index + 1)
        case .tick where isPlaying:
            if index < lines.count - 1 {
                index += 1
            } else {
                isPlaying = false
            }
        default:
            return
        }
        if index != previousIndex || isPlaying != wasPlaying {
            revision += 1
        }
    }

    public func reset() async {
        index = 0
        isPlaying = false
        revision += 1
    }
}
