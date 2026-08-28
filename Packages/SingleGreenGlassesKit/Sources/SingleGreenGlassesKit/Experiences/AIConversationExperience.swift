import Combine
import Foundation

@MainActor
public final class AIConversationExperience: ExperienceSession {
    public let descriptor: ExperienceDescriptor
    private let controller: VoiceConversationController
    private var updateSource: ExperienceUpdateSource = .spontaneous

    public init(controller: VoiceConversationController, providerDetail: String) {
        self.controller = controller
        self.descriptor = ExperienceDescriptor(
            kind: .conversation,
            displayName: "AI 对话",
            detail: providerDetail,
            systemImageName: "waveform.circle",
            capabilities: [.network, .microphone, .backgroundUpdates],
            actions: [
                ExperienceActionDescriptor(
                    id: BuiltInExperienceActions.primaryID,
                    event: .tap,
                    placement: .primary,
                    titleSource: .snapshotPrimaryAction,
                    iconSource: .controlStatePrimaryAction(fallback: "waveform"),
                    accessibilityLabel: "控制 AI 对话",
                    availability: .controlStateAllowsPrimaryAction
                )
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
                continuation.yield(
                    (self?.updateSource ?? .spontaneous).makeUpdate(snapshot)
                )
            }
            let lifetime = ObservationLifetime(observation)
            continuation.onTermination = { _ in
                Task { @MainActor in
                    lifetime.cancel()
                }
            }
        }
    }

    public func handle(_ event: DemoEvent) async {
        updateSource = .current
        switch event {
        case .tap:
            await controller.toggleConversation()
        case .reset:
            await reset()
        case .swipeUp, .swipeDown, .triggerAlert, .tick:
            break
        }
    }

    public func reset() async {
        updateSource = .current
        await controller.resetConversation()
    }

    public func shutdown() async {
        await controller.shutdown()
    }
}

@MainActor
private final class ObservationLifetime {
    private let observation: AnyCancellable

    init(_ observation: AnyCancellable) {
        self.observation = observation
    }

    func cancel() {
        observation.cancel()
    }
}
