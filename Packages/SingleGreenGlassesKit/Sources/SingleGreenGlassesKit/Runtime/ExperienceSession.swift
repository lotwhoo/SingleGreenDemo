import Foundation

public struct ExperienceControlState: Equatable, Sendable {
    public let statusTitle: String
    public let statusDetail: String
    public let errorMessage: String?
    public let primaryActionSystemImage: String
    public let allowsPrimaryAction: Bool

    public init(
        statusTitle: String,
        statusDetail: String,
        errorMessage: String?,
        primaryActionSystemImage: String,
        allowsPrimaryAction: Bool
    ) {
        self.statusTitle = statusTitle
        self.statusDetail = statusDetail
        self.errorMessage = errorMessage
        self.primaryActionSystemImage = primaryActionSystemImage
        self.allowsPrimaryAction = allowsPrimaryAction
    }
}

public struct ExperienceSnapshot: Equatable, Sendable {
    public let scene: HUDScene
    public let primaryActionTitle: String
    public let eventDescription: String
    public let controlState: ExperienceControlState?

    public init(
        scene: HUDScene,
        primaryActionTitle: String,
        eventDescription: String,
        controlState: ExperienceControlState? = nil
    ) {
        self.scene = scene
        self.primaryActionTitle = primaryActionTitle
        self.eventDescription = eventDescription
        self.controlState = controlState
    }
}

public struct ExperienceCommandToken: Equatable, Hashable, Sendable {
    private let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }
}

public enum ExperienceUpdateProvenance: Equatable, Sendable {
    case spontaneous
    case command(ExperienceCommandToken)
}

public struct ExperienceUpdate: Equatable, Sendable {
    public let snapshot: ExperienceSnapshot
    public let provenance: ExperienceUpdateProvenance

    public init(snapshot: ExperienceSnapshot, provenance: ExperienceUpdateProvenance) {
        self.snapshot = snapshot
        self.provenance = provenance
    }
}

enum ExperienceCommandContext {
    @TaskLocal static var currentToken: ExperienceCommandToken?
}

public struct ExperienceUpdateSource: Sendable {
    private let provenance: ExperienceUpdateProvenance

    private init(provenance: ExperienceUpdateProvenance) {
        self.provenance = provenance
    }

    /// Captures the current Runtime command provenance for use by a later callback.
    /// Capture this value while handling the command, then call `makeUpdate(_:)` later.
    public static var current: ExperienceUpdateSource {
        guard let token = ExperienceCommandContext.currentToken else {
            return .spontaneous
        }
        return ExperienceUpdateSource(provenance: .command(token))
    }

    /// Marks later callback output as independent from any Runtime command.
    public static var spontaneous: ExperienceUpdateSource {
        ExperienceUpdateSource(provenance: .spontaneous)
    }

    public func makeUpdate(_ snapshot: ExperienceSnapshot) -> ExperienceUpdate {
        ExperienceUpdate(snapshot: snapshot, provenance: provenance)
    }

    /// Compatibility shorthand for updates emitted synchronously or from an inherited child Task.
    public static func current(_ snapshot: ExperienceSnapshot) -> ExperienceUpdate {
        current.makeUpdate(snapshot)
    }

    /// Compatibility shorthand for an immediately emitted spontaneous update.
    public static func spontaneous(_ snapshot: ExperienceSnapshot) -> ExperienceUpdate {
        spontaneous.makeUpdate(snapshot)
    }
}

@MainActor
public protocol ExperienceSession: AnyObject {
    var descriptor: ExperienceDescriptor { get }
    var kind: ExperienceKind { get }
    var scene: HUDScene { get }
    var primaryActionTitle: String { get }
    var controlState: ExperienceControlState? { get }

    func currentSnapshot(eventDescription: String) -> ExperienceSnapshot
    func updates() -> AsyncStream<ExperienceUpdate>
    func handle(_ event: DemoEvent) async
    func handle(_ action: ExperienceActionEvent) async
    func reset() async
    func shutdown() async
}

public extension ExperienceSession {
    var kind: ExperienceKind { descriptor.kind }
    var controlState: ExperienceControlState? { nil }

    func currentSnapshot(eventDescription: String) -> ExperienceSnapshot {
        ExperienceSnapshot(
            scene: scene,
            primaryActionTitle: primaryActionTitle,
            eventDescription: eventDescription,
            controlState: controlState
        )
    }

    func updates() -> AsyncStream<ExperienceUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Preserves the legacy built-in input surface while allowing extension-owned actions.
    /// A custom experience overrides this method and handles its own open action values.
    func handle(_ action: ExperienceActionEvent) async {
        guard let event = action.compatibleDemoEvent else { return }
        await handle(event)
    }

    func shutdown() async {}
}
