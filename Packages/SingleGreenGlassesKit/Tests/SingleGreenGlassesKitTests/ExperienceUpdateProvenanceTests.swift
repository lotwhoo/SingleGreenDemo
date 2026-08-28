import Combine
import XCTest
import SingleGreenGlassesKit

@MainActor
final class ExperienceUpdateProvenanceTests: XCTestCase {
    func testDescendantUpdateAfterHandlerReturnIsAcceptedUntilNewerCommand() async {
        let session = ProvenanceExperience(kind: .navigation, handleBehavior: .descendant)
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.handle(.tap)
        await waitUntil { session.readyCommandIDs.contains(1) }
        XCTAssertEqual(runtime.lastEventDescription, "tap")

        session.releaseCommand(id: 1)
        await waitUntil { runtime.scene.revision == 101 }

        XCTAssertEqual(runtime.lastEventDescription, "command_1")
    }

    func testOldCommandDescendantUpdateAfterNewerCommandIsRejected() async {
        let session = ProvenanceExperience(kind: .navigation, handleBehavior: .descendant)
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.handle(.tap)
        await waitUntil { session.readyCommandIDs.contains(1) }
        await runtime.handle(.swipeDown)
        await waitUntil { session.readyCommandIDs.contains(2) }

        session.releaseCommand(id: 1)
        await Task.yield()
        XCTAssertEqual(runtime.scene.revision, 0)
        XCTAssertEqual(runtime.lastEventDescription, "swipe_down")

        session.releaseCommand(id: 2)
        await waitUntil { runtime.scene.revision == 102 }
        XCTAssertEqual(runtime.lastEventDescription, "command_2")
    }

    func testSpontaneousUpdateFromActiveSessionIsAccepted() async {
        let session = ProvenanceExperience(kind: .navigation)
        let runtime = ExperienceRuntime(sessions: [session])

        session.emitSpontaneous(revision: 77)
        await waitUntil { runtime.scene.revision == 77 }

        XCTAssertEqual(runtime.lastEventDescription, "spontaneous_77")
    }

    func testTaggedAndSpontaneousUpdatesFromInactiveSessionAreRejected() async {
        let origin = ProvenanceExperience(kind: .navigation, handleBehavior: .descendant)
        let destination = ProvenanceExperience(kind: .caption)
        let runtime = ExperienceRuntime(sessions: [origin, destination])

        await runtime.handle(.tap)
        await waitUntil { origin.readyCommandIDs.contains(1) }
        await runtime.activate(.caption)
        let destinationSnapshot = runtime.snapshot

        origin.releaseCommand(id: 1)
        origin.emitSpontaneous(revision: 88)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(runtime.snapshot, destinationSnapshot)
    }

    func testBufferedOldCommandUpdateIsRejectedAfterNewerCommand() async {
        let session = ProvenanceExperience(kind: .navigation, handleBehavior: .synchronous)
        let runtime = ExperienceRuntime(sessions: [session])
        var publishedRevisions: [Int] = []
        let observation = runtime.$snapshot.dropFirst().sink {
            publishedRevisions.append($0.scene.revision)
        }

        await runtime.handle(.tap)
        await runtime.handle(.swipeDown)
        await waitUntil { runtime.scene.revision == 102 }

        XCTAssertFalse(publishedRevisions.contains(101))
        XCTAssertEqual(runtime.scene.revision, 102)
        XCTAssertEqual(runtime.lastEventDescription, "command_2")
        withExtendedLifetime(observation) {}
    }

    func testResetCommandInvalidatesEarlierDescendantUpdate() async {
        let session = ProvenanceExperience(kind: .navigation, handleBehavior: .descendant)
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.handle(.tap)
        await waitUntil { session.readyCommandIDs.contains(1) }
        await runtime.handle(.reset)

        session.releaseCommand(id: 1)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(runtime.scene.revision, 0)
        XCTAssertEqual(runtime.lastEventDescription, "reset")
    }

    func testActivationCommandInvalidatesEarlierDescendantUpdate() async {
        let origin = ProvenanceExperience(kind: .navigation, handleBehavior: .descendant)
        let destination = ProvenanceExperience(kind: .caption)
        let runtime = ExperienceRuntime(sessions: [origin, destination])

        await runtime.handle(.tap)
        await waitUntil { origin.readyCommandIDs.contains(1) }
        await runtime.activate(.caption)

        origin.releaseCommand(id: 1)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(runtime.scene.sceneID, "provenance_caption")
        XCTAssertEqual(runtime.lastEventDescription, "activate_caption")
    }

    func testCapturedPublicUpdateSourceTagsLaterCallbackOutsideTaskLocalContext() async {
        let session = ProvenanceExperience(kind: .navigation, handleBehavior: .callbackCapture)
        let runtime = ExperienceRuntime(sessions: [session])

        await runtime.handle(.tap)
        session.emitCapturedCallback(commandID: 1, revision: 111)
        await waitUntil { runtime.scene.revision == 111 }
        XCTAssertEqual(runtime.lastEventDescription, "callback_1")

        await runtime.handle(.swipeDown)
        let newerCommandSnapshot = runtime.snapshot
        session.emitCapturedCallback(commandID: 1, revision: 119)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(runtime.snapshot, newerCommandSnapshot)

        session.emitCapturedCallback(commandID: 2, revision: 122)
        await waitUntil { runtime.scene.revision == 122 }
        XCTAssertEqual(runtime.lastEventDescription, "callback_2")
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for provenance fixture")
    }
}

@MainActor
private final class ProvenanceExperience: ExperienceSession {
    enum Behavior {
        case none
        case synchronous
        case descendant
        case callbackCapture
    }

    let descriptor: ExperienceDescriptor
    let scene: HUDScene
    let primaryActionTitle = "Run"
    private(set) var readyCommandIDs: Set<Int> = []

    private let handleBehavior: Behavior
    private var commandSequence = 0
    private var pendingCommands: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callbackSources: [Int: ExperienceUpdateSource] = [:]
    private let stream: AsyncStream<ExperienceUpdate>
    private let continuation: AsyncStream<ExperienceUpdate>.Continuation

    init(kind: ExperienceKind, handleBehavior: Behavior = .none) {
        self.descriptor = ExperienceDescriptor(
            kind: kind,
            displayName: "Provenance \(kind.rawValue)",
            detail: "Deterministic update provenance fixture",
            systemImageName: "point.3.connected.trianglepath.dotted",
            actions: [
                ExperienceActionDescriptor(
                    id: "primary",
                    event: .tap,
                    placement: .primary,
                    titleSource: .fixed("Run"),
                    iconSource: .fixed("play.fill"),
                    accessibilityLabel: "Run provenance command"
                ),
                ExperienceActionDescriptor(
                    id: "newer",
                    event: .swipeDown,
                    placement: .secondary,
                    titleSource: .fixed("Newer"),
                    iconSource: .fixed("forward.fill"),
                    accessibilityLabel: "Run newer provenance command"
                )
            ]
        )
        self.scene = HUDScene(
            sceneID: "provenance_\(kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
        self.handleBehavior = handleBehavior
        let (stream, continuation) = AsyncStream<ExperienceUpdate>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.stream = stream
        self.continuation = continuation
    }

    func updates() -> AsyncStream<ExperienceUpdate> { stream }

    func handle(_ event: DemoEvent) async {
        commandSequence += 1
        let commandID = commandSequence
        switch handleBehavior {
        case .none:
            break
        case .synchronous:
            continuation.yield(ExperienceUpdateSource.current(commandSnapshot(id: commandID)))
        case .descendant:
            // Child Task inherits Runtime's task-local command token. Task.detached must not be used.
            Task { @MainActor [weak self] in
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    self.pendingCommands[commandID] = continuation
                    self.readyCommandIDs.insert(commandID)
                }
                self.continuation.yield(ExperienceUpdateSource.current(
                    self.commandSnapshot(id: commandID)
                ))
            }
        case .callbackCapture:
            callbackSources[commandID] = .current
        }
    }

    func reset() async {}

    func releaseCommand(id: Int) {
        pendingCommands.removeValue(forKey: id)?.resume()
    }

    func emitSpontaneous(revision: Int) {
        continuation.yield(ExperienceUpdateSource.spontaneous(ExperienceSnapshot(
            scene: HUDScene(
                sceneID: "spontaneous_\(descriptor.kind.rawValue)",
                revision: revision,
                presentation: .focused,
                elements: []
            ),
            primaryActionTitle: primaryActionTitle,
            eventDescription: "spontaneous_\(revision)"
        )))
    }

    func emitCapturedCallback(commandID: Int, revision: Int) {
        guard let source = callbackSources[commandID] else { return }
        continuation.yield(source.makeUpdate(ExperienceSnapshot(
            scene: HUDScene(
                sceneID: "callback_\(descriptor.kind.rawValue)_\(commandID)",
                revision: revision,
                presentation: .result,
                elements: []
            ),
            primaryActionTitle: primaryActionTitle,
            eventDescription: "callback_\(commandID)"
        )))
    }

    private func commandSnapshot(id: Int) -> ExperienceSnapshot {
        ExperienceSnapshot(
            scene: HUDScene(
                sceneID: "command_\(descriptor.kind.rawValue)_\(id)",
                revision: 100 + id,
                presentation: .result,
                elements: []
            ),
            primaryActionTitle: primaryActionTitle,
            eventDescription: "command_\(id)"
        )
    }
}
