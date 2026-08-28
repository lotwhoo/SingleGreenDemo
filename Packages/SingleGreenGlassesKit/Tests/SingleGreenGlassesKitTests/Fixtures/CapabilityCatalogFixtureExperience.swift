import Foundation
@testable import SingleGreenGlassesKit

/// Reusable session for testing host registration and descriptor-driven controls.
/// It intentionally owns no UI or provider code and can publish control-only snapshots.
/// External callbacks should capture `ExperienceUpdateSource.current` during `handle(_:)`
/// and later publish with `source.makeUpdate(snapshot)`; independent inputs use `.spontaneous`.
@MainActor
final class CapabilityCatalogFixtureExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    private(set) var scene: HUDScene
    private(set) var primaryActionTitle: String
    private(set) var controlState: ExperienceControlState?
    private(set) var receivedEvents: [DemoEvent] = []

    private let stream: AsyncStream<ExperienceUpdate>
    private let continuation: AsyncStream<ExperienceUpdate>.Continuation

    init(
        descriptor: ExperienceDescriptor = CapabilityCatalogFixtureExample.makeDescriptor(),
        scene: HUDScene? = nil,
        primaryActionTitle: String = "Run fixture",
        controlState: ExperienceControlState? = nil
    ) {
        self.descriptor = descriptor
        self.scene = scene ?? HUDScene(
            sceneID: "capability_catalog_fixture_\(descriptor.kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
        self.primaryActionTitle = primaryActionTitle
        self.controlState = controlState
        let (stream, continuation) = AsyncStream<ExperienceUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func updates() -> AsyncStream<ExperienceUpdate> { stream }

    func handle(_ event: DemoEvent) async {
        receivedEvents.append(event)
        scene = HUDScene(
            sceneID: scene.sceneID,
            revision: scene.revision + 1,
            presentation: scene.presentation,
            elements: scene.elements
        )
    }

    func reset() async {}

    func emitControlOnlySnapshot(
        primaryActionTitle: String,
        controlState: ExperienceControlState,
        eventDescription: String = "control_only"
    ) {
        self.primaryActionTitle = primaryActionTitle
        self.controlState = controlState
        continuation.yield(ExperienceUpdateSource.spontaneous(
            currentSnapshot(eventDescription: eventDescription)
        ))
    }
}
