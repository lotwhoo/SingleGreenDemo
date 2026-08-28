@testable import SingleGreenGlassesKit

/// Copy checklist for a new descriptor-driven experience fixture:
/// 1. Choose a unique `ExperienceKind` registration and non-blank host metadata.
/// 2. Declare only resources the experience itself consumes; host camera preview is not a capability.
/// 3. Give actions stable IDs and deterministic order, with no more than one primary action.
/// 4. Map only interactive action events; keep reset as the host's generic debug command.
/// 5. Register the session. Host menus and controls must render without a kind-specific branch.
/// 6. For an external callback, capture `let source: ExperienceUpdateSource = .current`
///    inside `handle(_:)`, then call `source.makeUpdate(snapshot)` when the callback arrives.
/// 7. Inherited child `Task` values may use `.current` directly. Do not use `Task.detached`,
///    which intentionally loses command provenance; use `.spontaneous` only for independent input.
enum CapabilityCatalogFixtureExample {
    static func makeDescriptor(
        kind: ExperienceKind = .caption,
        displayName: String = "Capability fixture",
        detail: String = "Descriptor-owned host metadata",
        systemImageName: String = "wand.and.stars",
        capabilities: ExperienceCapabilities = [.camera],
        actions: [ExperienceActionDescriptor] = [
            ExperienceActionDescriptor(
                id: "fixture_action",
                event: .tap,
                placement: .secondary,
                titleSource: .fixed("Run fixture"),
                iconSource: .fixed("play.fill"),
                accessibilityLabel: "Run capability fixture"
            )
        ]
    ) -> ExperienceDescriptor {
        ExperienceDescriptor(
            kind: kind,
            displayName: displayName,
            detail: detail,
            systemImageName: systemImageName,
            capabilities: capabilities,
            actions: actions
        )
    }
}
