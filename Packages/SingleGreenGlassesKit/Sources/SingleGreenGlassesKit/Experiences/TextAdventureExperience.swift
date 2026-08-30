import Combine
import Foundation

@MainActor
public final class TextAdventureExperience: ExperienceSession {
    public static let kind = ExperienceKind("text_adventure.green_signal")
    public static let leftAction = ExperienceActionEvent("text_adventure.left")
    public static let rightAction = ExperienceActionEvent("text_adventure.right")
    public static let upAction = ExperienceActionEvent("text_adventure.up")
    public static let downAction = ExperienceActionEvent("text_adventure.down")

    public let descriptor: ExperienceDescriptor
    private let controller: TextAdventureController
    private var updateSource: ExperienceUpdateSource = .spontaneous

    public init(controller: TextAdventureController, providerDetail: String = "AI 文字 Agent") {
        self.controller = controller
        self.descriptor = ExperienceDescriptor(
            kind: Self.kind,
            displayName: "异闻信号",
            detail: providerDetail,
            systemImageName: "text.book.closed.fill",
            capabilities: [.network, .backgroundUpdates],
            actions: [
                Self.action(id: "left", event: Self.leftAction, title: "A 选择", icon: "arrow.left", label: "选择 A"),
                Self.action(id: "right", event: Self.rightAction, title: "B / 开始", icon: "arrow.right", label: "选择 B 或开始"),
                Self.action(id: "up", event: Self.upAction, title: "回顾", icon: "arrow.up", label: "查看上回回顾"),
                Self.action(id: "down", event: Self.downAction, title: "状态", icon: "arrow.down", label: "查看状态和提示")
            ]
        )
    }

    public var scene: HUDScene { controller.snapshot.scene }
    public var primaryActionTitle: String { controller.snapshot.primaryActionTitle }
    public var controlState: ExperienceControlState? { controller.snapshot.controlState }

    public func currentSnapshot(eventDescription: String) -> ExperienceSnapshot {
        controller.snapshot
    }

    public func updates() -> AsyncStream<ExperienceUpdate> {
        let controller = controller
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = controller.$snapshot.sink { [weak self] snapshot in
                continuation.yield((self?.updateSource ?? .spontaneous).makeUpdate(snapshot))
            }
            let lifetime = TextAdventureObservationLifetime(observation)
            continuation.onTermination = { _ in
                Task { @MainActor in lifetime.cancel() }
            }
        }
    }

    public func handle(_ event: DemoEvent) async {
        if event == .reset { await reset() }
    }

    public func handle(_ action: ExperienceActionEvent) async {
        updateSource = .current
        if action == Self.leftAction {
            controller.handle(.left)
        } else if action == Self.rightAction {
            controller.handle(.right)
        } else if action == Self.upAction {
            controller.handle(.up)
        } else if action == Self.downAction {
            controller.handle(.down)
        }
    }

    public func reset() async {
        updateSource = .current
        controller.reset()
    }

    public func shutdown() async {
        await controller.shutdown()
    }

    private static func action(
        id: String,
        event: ExperienceActionEvent,
        title: String,
        icon: String,
        label: String
    ) -> ExperienceActionDescriptor {
        ExperienceActionDescriptor(
            id: id,
            event: event,
            placement: .secondary,
            titleSource: .fixed(title),
            iconSource: .fixed(icon),
            accessibilityLabel: label
        )
    }
}

@MainActor
private final class TextAdventureObservationLifetime {
    private let observation: AnyCancellable

    init(_ observation: AnyCancellable) {
        self.observation = observation
    }

    func cancel() {
        observation.cancel()
    }
}
