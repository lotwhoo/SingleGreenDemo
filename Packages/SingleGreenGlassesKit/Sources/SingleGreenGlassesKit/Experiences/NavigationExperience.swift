import Foundation

@MainActor
public final class NavigationExperience: ExperienceSession {
    public let descriptor = ExperienceDescriptor(
        kind: .navigation,
        displayName: "导航",
        detail: "体验场景 · 本地样例",
        systemImageName: "location.north.line",
        actions: [
            BuiltInExperienceActions.primary(
                event: .tap,
                icon: "location.fill",
                accessibilityLabel: "展开或收起导航详情"
            )
        ] + BuiltInExperienceActions.standardSecondary
    )

    public init() {}

    private struct Step {
        let symbol: String
        let distance: String
        let road: String
        let detail: String
    }

    private let steps = [
        Step(symbol: "arrow.turn.up.right", distance: "120 m", road: "建国西路", detail: "前方路口右转"),
        Step(symbol: "arrow.up", distance: "450 m", road: "建国西路", detail: "沿当前道路直行"),
        Step(symbol: "flag.checkered", distance: "到达", road: "目的地", detail: "目的地在道路右侧")
    ]

    private var index = 0
    private var expanded = false
    private var revision = 0

    public var primaryActionTitle: String {
        expanded ? "收起导航详情" : "展开导航详情"
    }

    public var scene: HUDScene {
        let step = steps[index]
        return HUDScene(
            sceneID: "navigation_\(index)",
            revision: revision,
            presentation: index == steps.count - 1 ? .result : (expanded ? .focused : .compact),
            elements: [
                HUDElement(
                    id: "direction",
                    frame: NormalizedRect(x: 0.36, y: 0.02, width: 0.28, height: 0.30),
                    content: .symbol(step.symbol)
                ),
                HUDElement(
                    id: "distance",
                    frame: NormalizedRect(x: 0.08, y: 0.34, width: 0.84, height: 0.30),
                    content: .text(step.distance, .value)
                ),
                HUDElement(
                    id: "road",
                    frame: NormalizedRect(x: 0.10, y: 0.68, width: 0.80, height: 0.16),
                    content: .text(expanded ? "\(step.detail) · \(step.road)" : step.road, .detail)
                ),
                HUDElement(
                    id: "progress",
                    frame: NormalizedRect(x: 0.20, y: 0.90, width: 0.60, height: 0.05),
                    content: .progress(Double(index + 1) / Double(steps.count))
                )
            ]
        )
    }

    public func handle(_ event: DemoEvent) async {
        let previousIndex = index
        let previousExpanded = expanded
        switch event {
        case .tap:
            expanded.toggle()
        case .swipeUp:
            index = max(0, index - 1)
        case .swipeDown:
            index = min(steps.count - 1, index + 1)
        default:
            return
        }
        if index != previousIndex || expanded != previousExpanded {
            revision += 1
        }
    }

    public func reset() async {
        index = 0
        expanded = false
        revision += 1
    }
}
