import Foundation

struct ExperienceSnapshot {
    var scene: HUDScene
    var primaryActionTitle: String
    var eventDescription: String
}

@MainActor
protocol ExperienceSession: AnyObject {
    var kind: ExperienceKind { get }
    var scene: HUDScene { get }
    var primaryActionTitle: String { get }

    func updates() -> AsyncStream<ExperienceSnapshot>
    func handle(_ event: DemoEvent) async
    func reset() async
}

extension ExperienceSession {
    func updates() -> AsyncStream<ExperienceSnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
