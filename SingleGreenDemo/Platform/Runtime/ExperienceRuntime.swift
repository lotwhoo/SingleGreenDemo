import SwiftUI

@MainActor
final class ExperienceRuntime: ObservableObject {
    @Published private(set) var selectedKind: ExperienceKind
    @Published private(set) var scene: HUDScene
    @Published private(set) var primaryActionTitle: String
    @Published private(set) var lastEventDescription = "ready"

    private let sessions: [ExperienceKind: any ExperienceSession]
    private(set) var rejectedDuplicateKinds: [ExperienceKind]
    private var commandGeneration = 0
    private var updatesTask: Task<Void, Never>?

    init(sessions: [any ExperienceSession]? = nil) {
        let registered = sessions ?? [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience()
        ]
        var registry: [ExperienceKind: any ExperienceSession] = [:]
        var duplicates: [ExperienceKind] = []
        for session in registered {
            if registry[session.kind] == nil {
                registry[session.kind] = session
            } else {
                duplicates.append(session.kind)
            }
        }
        let initial = registry[.systemStatus]
            ?? registered.first(where: { registry[$0.kind] === $0 })
            ?? SystemStatusExperience()

        self.sessions = registry
        self.rejectedDuplicateKinds = duplicates
        self.selectedKind = initial.kind
        self.scene = initial.scene
        self.primaryActionTitle = initial.primaryActionTitle
        if let duplicate = duplicates.first {
            self.lastEventDescription = "duplicate_experience_\(duplicate.rawValue)"
        }
        observe(initial)
    }

    var availableKinds: [ExperienceKind] {
        ExperienceKind.allCases.filter { sessions[$0] != nil }
    }

    func activate(_ kind: ExperienceKind) async {
        guard let session = sessions[kind] else {
            lastEventDescription = "experience_not_found"
            return
        }

        commandGeneration += 1
        let generation = commandGeneration
        if let previous = sessions[selectedKind], previous !== session {
            await previous.reset()
        }
        guard generation == commandGeneration else { return }
        await session.reset()
        guard generation == commandGeneration else { return }
        selectedKind = kind
        publish(session, eventName: "activate_\(kind.rawValue)")
        observe(session)
    }

    func handle(_ event: DemoEvent) async {
        guard let session = sessions[selectedKind] else {
            lastEventDescription = "experience_not_found"
            return
        }

        commandGeneration += 1
        let generation = commandGeneration
        if event == .reset {
            await session.reset()
        } else {
            await session.handle(event)
        }
        guard generation == commandGeneration,
              sessions[selectedKind] === session else { return }
        publish(session, eventName: event.debugName)
    }

    private func observe(_ session: any ExperienceSession) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            for await snapshot in session.updates() {
                guard !Task.isCancelled, let self,
                      self.sessions[self.selectedKind] === session else { return }
                self.scene = snapshot.scene
                self.primaryActionTitle = snapshot.primaryActionTitle
                self.lastEventDescription = snapshot.eventDescription
            }
        }
    }

    private func publish(_ session: any ExperienceSession, eventName: String) {
        scene = session.scene
        primaryActionTitle = session.primaryActionTitle
        lastEventDescription = eventName
    }
}
