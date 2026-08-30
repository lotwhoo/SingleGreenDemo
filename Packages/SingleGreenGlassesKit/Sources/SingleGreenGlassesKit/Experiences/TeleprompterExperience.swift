import Combine
import Foundation

@MainActor
public final class TeleprompterExperience: ExperienceSession {
    public static let kind = ExperienceKind("teleprompter.asr")
    public static let leftAction = ExperienceActionEvent("teleprompter.left")
    public static let rightAction = ExperienceActionEvent("teleprompter.right")
    public static let upAction = ExperienceActionEvent("teleprompter.up")
    public static let downAction = ExperienceActionEvent("teleprompter.down")

    public let descriptor: ExperienceDescriptor
    private let controller: TeleprompterController
    private var updateSource: ExperienceUpdateSource = .spontaneous

    public init(controller: TeleprompterController) {
        self.controller = controller
        self.descriptor = ExperienceDescriptor(
            kind: Self.kind,
            displayName: "语音提词器",
            detail: "本地稿件 · ASR 自动跟随",
            systemImageName: "text.line.first.and.arrowtriangle.forward",
            capabilities: [.microphone, .network, .backgroundUpdates],
            actions: [
                Self.action(id: "left", event: Self.leftAction, title: "上一句", icon: "arrow.left", label: "返回上一句"),
                Self.action(id: "right", event: Self.rightAction, title: "下一句", icon: "arrow.right", label: "前往下一句"),
                ExperienceActionDescriptor(
                    id: "up",
                    event: Self.upAction,
                    placement: .primary,
                    titleSource: .snapshotPrimaryAction,
                    iconSource: .controlStatePrimaryAction(fallback: "play.fill"),
                    accessibilityLabel: "开始、暂停或继续语音跟随",
                    availability: .controlStateAllowsPrimaryAction
                ),
                Self.action(id: "down", event: Self.downAction, title: "重对齐 / 手动", icon: "arrow.down", label: "重新对齐或切换手动模式")
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
            let lifetime = TeleprompterObservationLifetime(observation)
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
            await controller.movePrevious()
        } else if action == Self.rightAction {
            await controller.moveNext()
        } else if action == Self.upAction {
            await controller.toggleFollowing()
        } else if action == Self.downAction {
            await controller.reanchorOrToggleManualFallback()
        }
    }

    public func reset() async {
        updateSource = .current
        await controller.reset()
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
private final class TeleprompterObservationLifetime {
    private let observation: AnyCancellable

    init(_ observation: AnyCancellable) {
        self.observation = observation
    }

    func cancel() { observation.cancel() }
}
