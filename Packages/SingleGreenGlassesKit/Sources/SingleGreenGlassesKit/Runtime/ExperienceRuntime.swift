import Combine

@MainActor
public final class ExperienceRuntime: ObservableObject {
    private struct CommandInvocation {
        let generation: Int
        let token: ExperienceCommandToken
    }

    @Published public private(set) var selectedKind: ExperienceKind
    @Published public private(set) var snapshot: ExperienceSnapshot

    private let sessions: [ExperienceKind: any ExperienceSession]
    private let catalog: ExperienceCatalog
    private var commandGeneration = 0
    private var activeCommandToken: ExperienceCommandToken?
    private var updateTasks: [ExperienceKind: Task<Void, Never>] = [:]

    public init(sessions: [any ExperienceSession]? = nil) {
        let registered = sessions ?? [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience()
        ]
        let catalog: ExperienceCatalog
        do {
            catalog = try ExperienceCatalog(descriptors: registered.map(\.descriptor))
        } catch {
            preconditionFailure("Invalid experience catalog: \(error)")
        }
        let registry = Dictionary(uniqueKeysWithValues: registered.map { ($0.kind, $0) })
        let initial = registry[.systemStatus]
            ?? registered.first
            ?? SystemStatusExperience()

        self.sessions = registry
        self.catalog = catalog
        self.selectedKind = initial.kind
        self.snapshot = initial.currentSnapshot(eventDescription: "ready")
        for session in registered {
            observe(session)
        }
    }

    deinit {
        for task in updateTasks.values {
            task.cancel()
        }
    }

    public var scene: HUDScene { snapshot.scene }
    public var primaryActionTitle: String { snapshot.primaryActionTitle }
    public var lastEventDescription: String { snapshot.eventDescription }
    public var controlState: ExperienceControlState? { snapshot.controlState }

    public var availableKinds: [ExperienceKind] {
        availableDescriptors.map(\.kind)
    }

    public var availableDescriptors: [ExperienceDescriptor] {
        catalog.descriptors
    }

    public var selectedDescriptor: ExperienceDescriptor {
        guard let descriptor = catalog.descriptor(for: selectedKind) else {
            preconditionFailure("Selected experience is missing from the validated catalog")
        }
        return descriptor
    }

    public var activeActions: [ResolvedExperienceAction] {
        selectedDescriptor.actions.map { $0.resolve(using: snapshot) }
    }

    public func activate(_ kind: ExperienceKind) async {
        await activate(kind, expectedKind: selectedKind)
    }

    public func activate(_ kind: ExperienceKind, expectedKind: ExperienceKind) async {
        guard selectedKind == expectedKind,
              let origin = sessions[expectedKind],
              sessions[selectedKind] === origin else { return }
        guard let destination = sessions[kind] else {
            publishEventDescription("experience_not_found")
            return
        }

        let completed = await runCommand(
            expectedKind: expectedKind,
            expectedSession: origin
        ) { command in
            if origin !== destination {
                await origin.reset()
                guard self.isCurrent(
                    command,
                    expectedKind: expectedKind,
                    expectedSession: origin
                ) else { return }
            }
            await destination.reset()
        }
        guard completed else { return }
        selectedKind = kind
        publish(destination, eventName: "activate_\(kind.rawValue)")
    }

    public func handle(_ event: DemoEvent) async {
        await handle(event, expectedKind: selectedKind)
    }

    public func handle(_ event: DemoEvent, expectedKind: ExperienceKind) async {
        guard selectedKind == expectedKind else { return }
        guard let expectedSession = sessions[expectedKind] else {
            publishEventDescription("experience_not_found")
            return
        }
        await execute(event, expectedKind: expectedKind, expectedSession: expectedSession)
    }

    public func performAction(id: String) async {
        await performAction(id: id, expectedKind: selectedKind)
    }

    public func performAction(id: String, expectedKind: ExperienceKind) async {
        guard selectedKind == expectedKind,
              let expectedSession = sessions[expectedKind],
              sessions[selectedKind] === expectedSession else { return }
        guard let action = activeActions.first(where: { $0.id == id }),
              action.isEnabled else { return }
        await executeAction(
            action.event,
            expectedKind: expectedKind,
            expectedSession: expectedSession
        )
    }

    /// Stops background observation and releases resources owned by registered sessions.
    public func shutdown() async {
        commandGeneration += 1
        activeCommandToken = nil
        let tasks = Array(updateTasks.values)
        updateTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        for session in sessions.values {
            await session.shutdown()
        }
    }

    private func execute(
        _ event: DemoEvent,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) async {
        let completed = await runCommand(
            expectedKind: expectedKind,
            expectedSession: expectedSession
        ) { _ in
            if event == .reset {
                await expectedSession.reset()
            } else {
                await expectedSession.handle(event)
            }
        }
        guard completed else { return }
        publish(expectedSession, eventName: event.debugName)
    }

    private func executeAction(
        _ action: ExperienceActionEvent,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) async {
        let completed = await runCommand(
            expectedKind: expectedKind,
            expectedSession: expectedSession
        ) { _ in
            await expectedSession.handle(action)
        }
        guard completed else { return }
        publish(expectedSession, eventName: action.rawValue)
    }

    private func runCommand(
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession,
        operation: (CommandInvocation) async -> Void
    ) async -> Bool {
        guard selectedKind == expectedKind,
              sessions[expectedKind] === expectedSession else { return false }

        commandGeneration += 1
        let generation = commandGeneration
        let token = ExperienceCommandToken()
        let command = CommandInvocation(generation: generation, token: token)
        activeCommandToken = token
        await ExperienceCommandContext.$currentToken.withValue(token) {
            await operation(command)
        }

        return isCurrent(
            command,
            expectedKind: expectedKind,
            expectedSession: expectedSession
        )
    }

    private func isCurrent(
        _ command: CommandInvocation,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) -> Bool {
        command.generation == commandGeneration
            && activeCommandToken == command.token
            && selectedKind == expectedKind
            && sessions[expectedKind] === expectedSession
    }

    private func observe(_ session: any ExperienceSession) {
        updateTasks[session.kind]?.cancel()
        updateTasks[session.kind] = Task { [weak self] in
            for await update in session.updates() {
                guard !Task.isCancelled, let self else { return }
                guard self.sessions[self.selectedKind] === session else { continue }
                if case .command(let token) = update.provenance,
                   token != self.activeCommandToken {
                    continue
                }
                self.assign(update.snapshot)
            }
        }
    }

    private func publish(_ session: any ExperienceSession, eventName: String) {
        assign(session.currentSnapshot(eventDescription: eventName))
    }

    private func publishEventDescription(_ eventDescription: String) {
        assign(ExperienceSnapshot(
            scene: snapshot.scene,
            primaryActionTitle: snapshot.primaryActionTitle,
            eventDescription: eventDescription,
            controlState: snapshot.controlState
        ))
    }

    private func assign(_ newSnapshot: ExperienceSnapshot) {
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
    }
}
