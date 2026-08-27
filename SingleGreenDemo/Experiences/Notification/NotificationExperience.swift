import Foundation

@MainActor
final class NotificationExperience: ExperienceSession {
    let kind: ExperienceKind = .notification
    private var isVisible = false
    private var revision = 0

    var primaryActionTitle: String {
        isVisible ? "确认提醒" : "触发提醒"
    }

    var scene: HUDScene {
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

    func handle(_ event: DemoEvent) async {
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

    func reset() async {
        isVisible = false
        revision += 1
    }
}
