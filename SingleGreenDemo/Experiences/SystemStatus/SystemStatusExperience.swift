import Foundation

@MainActor
final class SystemStatusExperience: ExperienceSession {
    let kind: ExperienceKind = .systemStatus
    private var index = 0
    private var expanded = false
    private var revision = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    var primaryActionTitle: String {
        expanded ? "收起状态" : "展开状态"
    }

    var scene: HUDScene {
        let cards: [(symbol: String, value: String, detail: String)] = [
            (
                "clock",
                now().formatted(date: .omitted, time: .shortened),
                expanded ? "设备时间 · 本地显示" : "当前时间"
            ),
            (
                "battery.75percent",
                "78%",
                expanded ? "模拟电量 · 非真实设备数据" : "模拟电量"
            ),
            (
                "link",
                "已连接",
                expanded ? "模拟连接状态 · LOCAL" : "模拟状态"
            )
        ]
        let card = cards[index]

        return HUDScene(
            sceneID: "system_status_\(index)",
            revision: revision,
            presentation: expanded ? .focused : .compact,
            elements: [
                HUDElement(
                    id: "symbol",
                    frame: NormalizedRect(x: 0.40, y: 0.08, width: 0.20, height: 0.22),
                    content: .symbol(card.symbol)
                ),
                HUDElement(
                    id: "value",
                    frame: NormalizedRect(x: 0.10, y: 0.34, width: 0.80, height: 0.30),
                    content: .text(card.value, .value)
                ),
                HUDElement(
                    id: "detail",
                    frame: NormalizedRect(x: 0.10, y: 0.70, width: 0.80, height: 0.20),
                    content: .text(card.detail, .detail)
                )
            ]
        )
    }

    func handle(_ event: DemoEvent) async {
        let previousIndex = index
        let previousExpanded = expanded
        switch event {
        case .tap:
            expanded.toggle()
        case .swipeUp:
            index = max(0, index - 1)
        case .swipeDown:
            index = min(2, index + 1)
        default:
            return
        }
        if index != previousIndex || expanded != previousExpanded {
            revision += 1
        }
    }

    func reset() async {
        index = 0
        expanded = false
        revision += 1
    }
}
