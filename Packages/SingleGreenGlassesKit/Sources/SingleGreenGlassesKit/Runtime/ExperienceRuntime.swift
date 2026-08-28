import Combine

@MainActor
public final class ExperienceRuntime: ObservableObject {
    private struct CommandInvocation {
        let generation: Int
        let token: ExperienceCommandToken
    }

    private struct Registration {
        let sessions: [ExperienceKind: any ExperienceSession]
        let catalog: ExperienceCatalog
        let initial: any ExperienceSession
    }

    @Published public private(set) var selectedKind: ExperienceKind
    @Published public private(set) var snapshot: ExperienceSnapshot

    private let sessions: [ExperienceKind: any ExperienceSession]
    private let catalog: ExperienceCatalog
    private var commandGeneration = 0
    private var activeCommandToken: ExperienceCommandToken?
    private var commandTasks: [ExperienceCommandToken: Task<Void, Never>] = [:]
    private var updateTasks: [ExperienceKind: Task<Void, Never>] = [:]
    private var isShutdown = false
    private var shutdownTask: Task<Void, Never>?

    public init(sessions: [any ExperienceSession]? = nil) {
        let registered = sessions ?? [
            SystemStatusExperience(),
            NavigationExperience(),
            NotificationExperience(),
            CaptionExperience()
        ]
        let registration: Registration
        do {
            registration = try Self.validate(registered)
        } catch {
            preconditionFailure("Invalid experience catalog: \(error)")
        }
        self.sessions = registration.sessions
        self.catalog = registration.catalog
        self.selectedKind = registration.initial.descriptor.kind
        self.snapshot = registration.initial.currentSnapshot(eventDescription: "ready")
        for session in registered {
            observe(session)
        }
    }

    /// Creates a runtime while surfacing invalid registrations as typed catalog errors.
    public init(validating sessions: [any ExperienceSession]) throws {
        let registered = sessions
        let registration = try Self.validate(registered)
        self.sessions = registration.sessions
        self.catalog = registration.catalog
        self.selectedKind = registration.initial.descriptor.kind
        self.snapshot = registration.initial.currentSnapshot(eventDescription: "ready")
        for session in registered {
            observe(session)
        }
    }

    private static func validate(_ registered: [any ExperienceSession]) throws -> Registration {
        let catalog = try ExperienceCatalog(descriptors: registered.map(\.descriptor))
        let registry = Dictionary(uniqueKeysWithValues: registered.map {
            ($0.descriptor.kind, $0)
        })
        let initial = registry[.systemStatus]
            ?? registered.first
            ?? SystemStatusExperience()
        return Registration(sessions: registry, catalog: catalog, initial: initial)
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
        guard !isShutdown else { return }
        await activate(kind, expectedKind: selectedKind)
    }

    public func activate(_ kind: ExperienceKind, expectedKind: ExperienceKind) async {
        guard !isShutdown,
              selectedKind == expectedKind,
              let origin = sessions[expectedKind],
              sessions[selectedKind] === origin else { return }
        guard let destination = sessions[kind] else {
            publishEventDescription("experience_not_found")
            return
        }

        await runCommand(
            expectedKind: expectedKind,
            expectedSession: origin,
            completion: {
                self.selectedKind = kind
                self.publish(destination, eventName: "activate_\(kind.rawValue)")
            }
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
    }

    public func handle(_ event: DemoEvent) async {
        guard !isShutdown else { return }
        await handle(event, expectedKind: selectedKind)
    }

    public func handle(_ event: DemoEvent, expectedKind: ExperienceKind) async {
        guard !isShutdown, selectedKind == expectedKind else { return }
        guard let expectedSession = sessions[expectedKind] else {
            publishEventDescription("experience_not_found")
            return
        }
        await execute(event, expectedKind: expectedKind, expectedSession: expectedSession)
    }

    public func performAction(id: String) async {
        guard !isShutdown else { return }
        await performAction(id: id, expectedKind: selectedKind)
    }

    public func performAction(id: String, expectedKind: ExperienceKind) async {
        guard !isShutdown,
              selectedKind == expectedKind,
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
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard !isShutdown else { return }
        isShutdown = true
        commandGeneration += 1
        activeCommandToken = nil
        let commands = Array(commandTasks.values)
        commandTasks.removeAll()
        for command in commands {
            command.cancel()
        }
        let observations = Array(updateTasks.values)
        updateTasks.removeAll()
        for observation in observations {
            observation.cancel()
        }
        let registeredSessions = Array(sessions.values)
        let task = Task { @MainActor in
            for command in commands {
                await command.value
            }
            for observation in observations {
                await observation.value
            }
            for session in registeredSessions {
                await session.shutdown()
            }
        }
        shutdownTask = task
        await task.value
    }

    private func execute(
        _ event: DemoEvent,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) async {
        await runCommand(
            expectedKind: expectedKind,
            expectedSession: expectedSession,
            completion: {
                self.publish(expectedSession, eventName: event.debugName)
            }
        ) { _ in
            if event == .reset {
                await expectedSession.reset()
            } else {
                await expectedSession.handle(event)
            }
        }
    }

    private func executeAction(
        _ action: ExperienceActionEvent,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) async {
        await runCommand(
            expectedKind: expectedKind,
            expectedSession: expectedSession,
            completion: {
                self.publish(expectedSession, eventName: action.rawValue)
            }
        ) { _ in
            await expectedSession.handle(action)
        }
    }

    private func runCommand(
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession,
        completion: @escaping () -> Void,
        operation: @escaping (CommandInvocation) async -> Void
    ) async {
        guard !isShutdown,
              selectedKind == expectedKind,
              sessions[expectedKind] === expectedSession else { return }

        commandGeneration += 1
        let generation = commandGeneration
        let token = ExperienceCommandToken()
        let command = CommandInvocation(generation: generation, token: token)
        activeCommandToken = token
        let task = Task { @MainActor in
            await ExperienceCommandContext.$currentToken.withValue(token) {
                await operation(command)
            }
            guard self.isCurrent(
                command,
                expectedKind: expectedKind,
                expectedSession: expectedSession
            ) else { return }
            completion()
        }
        commandTasks[token] = task
        await task.value
        commandTasks.removeValue(forKey: token)
    }

    private func isCurrent(
        _ command: CommandInvocation,
        expectedKind: ExperienceKind,
        expectedSession: any ExperienceSession
    ) -> Bool {
        command.generation == commandGeneration
            && !isShutdown
            && activeCommandToken == command.token
            && selectedKind == expectedKind
            && sessions[expectedKind] === expectedSession
    }

    private func observe(_ session: any ExperienceSession) {
        let kind = session.descriptor.kind
        updateTasks[kind]?.cancel()
        updateTasks[kind] = Task { [weak self] in
            for await update in session.updates() {
                guard !Task.isCancelled, let self else { return }
                guard !self.isShutdown else { return }
                guard self.sessions[self.selectedKind] === session else { continue }
                if case .command(let token) = update.provenance {
                    // Let a directly-following command publish its newer token
                    // before accepting a buffered descendant update.
                    await Task.yield()
                    guard !Task.isCancelled,
                          !self.isShutdown,
                          token == self.activeCommandToken else { continue }
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
        guard !isShutdown, snapshot != newSnapshot else { return }
        snapshot = newSnapshot
    }
}
