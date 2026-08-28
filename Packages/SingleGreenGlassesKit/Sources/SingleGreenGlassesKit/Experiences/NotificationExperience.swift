import Foundation

@MainActor
public final class NotificationExperience: ExperienceSession {
    public let descriptor = ExperienceDescriptor(
        kind: .notification,
        displayName: "通知",
        detail: "体验场景 · 本地样例",
        systemImageName: "bell",
        actions: [
            BuiltInExperienceActions.primary(
                event: .triggerAlert,
                icon: "bell.badge.fill",
                accessibilityLabel: "显示提醒"
            ),
            BuiltInExperienceActions.tap,
            BuiltInExperienceActions.swipeDown
        ]
    )
    private var isVisible = false
    private var revision = 0

    public init() {}

    public var primaryActionTitle: String {
        "显示提醒"
    }

    public var scene: HUDScene {
        if !isVisible {
            return HUDScene(
                sceneID: "notification_waiting",
                revision: revision,
                presentation: .compact,
                elements: [
                    HUDElement(
                        id: "symbol",
                        frame: NormalizedRect(x: 0.42, y: 0.20, width: 0.16, height: 0.20),
                        content: .symbol("bell")
                    ),
                    HUDElement(
                        id: "status",
                        frame: NormalizedRect(x: 0.12, y: 0.48, width: 0.76, height: 0.20),
                        content: .text("等待本地提醒", .title)
                    )
                ]
            )
        }

        return HUDScene(
            sceneID: "notification_alert",
            revision: revision,
            presentation: .alert,
            elements: [
                HUDElement(
                    id: "symbol",
                    frame: NormalizedRect(x: 0.13, y: 0.20, width: 0.18, height: 0.24),
                    content: .symbol("calendar")
                ),
                HUDElement(
                    id: "title",
                    frame: NormalizedRect(x: 0.34, y: 0.18, width: 0.54, height: 0.22),
                    content: .text("产品评审", .title)
                ),
                HUDElement(
                    id: "time",
                    frame: NormalizedRect(x: 0.20, y: 0.48, width: 0.60, height: 0.20),
                    content: .text("15 分钟后", .title)
                ),
                HUDElement(
                    id: "detail",
                    frame: NormalizedRect(x: 0.10, y: 0.72, width: 0.80, height: 0.16),
                    content: .text("会议室 A · 本地样例", .detail)
                )
            ]
        )
    }

    public func handle(_ event: DemoEvent) async {
        let wasVisible = isVisible
        switch event {
        case .triggerAlert:
            isVisible = true
        case .tap, .swipeDown:
            isVisible = false
        default:
            return
        }
        if isVisible != wasVisible {
            revision += 1
        }
    }

    public func reset() async {
        isVisible = false
        revision += 1
    }
}
