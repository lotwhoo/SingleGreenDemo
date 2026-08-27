import Combine
import Foundation

@MainActor
final class AIConversationExperience: ExperienceSession {
    let kind: ExperienceKind = .conversation
    private let controller: VoiceConversationController

    init(controller: VoiceConversationController) {
        self.controller = controller
    }

    var scene: HUDScene { controller.scene }
    var primaryActionTitle: String { controller.primaryActionTitle }

    func updates() -> AsyncStream<ExperienceSnapshot> {
        let controller = controller
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let observation = controller.$scene.sink { [weak controller] scene in
                guard let controller else {
                    continuation.finish()
                    return
                }
                continuation.yield(ExperienceSnapshot(
                    scene: scene,
                    primaryActionTitle: controller.primaryActionTitle,
                    eventDescription: controller.lastEventDescription
                ))
            }
            continuation.onTermination = { _ in
                observation.cancel()
            }
        }
    }

    func handle(_ event: DemoEvent) async {
        switch event {
        case .tap:
            await controller.toggleConversation()
        case .reset:
            await reset()
        case .swipeUp, .swipeDown, .triggerAlert, .tick:
            break
        }
    }

    func reset() async {
        await controller.resetConversation()
    }
}
