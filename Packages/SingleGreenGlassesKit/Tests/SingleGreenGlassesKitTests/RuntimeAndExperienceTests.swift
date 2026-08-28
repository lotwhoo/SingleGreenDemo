import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class RuntimeAndExperienceTests: XCTestCase {
    func testRuntimeDeallocationCancelsNonFinishingObservation() async {
        let session = NonFinishingObservationExperience()
        var runtime: ExperienceRuntime? = ExperienceRuntime(sessions: [session])
        weak let weakRuntime = runtime

        await waitUntil { session.hasSubscriber }
        runtime = nil

        await waitUntil { weakRuntime == nil && session.wasTerminated }
    }

    func testRuntimeShutdownCancelsObservationAndSessionResources() async {
        let session = NonFinishingObservationExperience()
        let runtime = ExperienceRuntime(sessions: [session])
        await waitUntil { session.hasSubscriber }

        await runtime.shutdown()

        XCTAssertTrue(session.wasTerminated)
        XCTAssertEqual(session.shutdownCount, 1)
    }

    func testRuntimeDefaultsToSystemStatusAndRegistersAllExperiences() async {
        let runtime = ExperienceRuntime()

        XCTAssertEqual(runtime.selectedKind, .systemStatus)
        XCTAssertEqual(runtime.availableKinds, [.systemStatus, .navigation, .notification, .caption])
        XCTAssertEqual(runtime.scene.presentation, .compact)
    }

    func testRuntimeWithoutSystemStatusPreservesFirstValidRegistrationOrder() {
        let caption = CaptionExperience()
        let navigation = NavigationExperience()
        let runtime = ExperienceRuntime(sessions: [caption, navigation])

        XCTAssertEqual(runtime.availableKinds, [.navigation, .caption])
        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(runtime.selectedDescriptor, caption.descriptor)
    }

    func testRuntimeReportsUnavailableExperience() async {
        let runtime = ExperienceRuntime(sessions: [NavigationExperience()])

        await runtime.activate(.caption)

        XCTAssertEqual(runtime.selectedKind, .navigation)
        XCTAssertEqual(runtime.lastEventDescription, "experience_not_found")
    }

    func testNavigationMovesWithinBoundsAndIgnoresBoundarySwipe() async {
        let session = NavigationExperience()
        let initialRevision = session.scene.revision

        await session.handle(.swipeUp)
        XCTAssertEqual(session.scene.revision, initialRevision)

        await session.handle(.swipeDown)
        await session.handle(.swipeDown)
        let finalScene = session.scene
        XCTAssertEqual(finalScene.presentation, .result)
        XCTAssertEqual(progress(in: finalScene), 1)

        await session.handle(.swipeDown)
        XCTAssertEqual(session.scene.revision, finalScene.revision)
    }

    func testNavigationTapExpandsAndResetRestoresInitialScene() async {
        let session = NavigationExperience()
        let initialID = session.scene.sceneID

        await session.handle(.tap)
        XCTAssertEqual(session.scene.presentation, .focused)
        await session.handle(.swipeDown)
        await session.reset()

        XCTAssertEqual(session.scene.sceneID, initialID)
        XCTAssertEqual(session.scene.presentation, .compact)
    }

    func testNotificationOnlyRevisesWhenVisibilityChanges() async {
        let session = NotificationExperience()
        let initialRevision = session.scene.revision

        XCTAssertEqual(session.primaryActionTitle, "显示提醒")

        await session.handle(.tap)
        XCTAssertEqual(session.scene.revision, initialRevision)

        await session.handle(.triggerAlert)
        XCTAssertEqual(session.scene.presentation, .alert)
        XCTAssertEqual(session.primaryActionTitle, "显示提醒")
        let alertRevision = session.scene.revision
        await session.handle(.triggerAlert)
        XCTAssertEqual(session.scene.revision, alertRevision)

        await session.handle(.swipeDown)
        XCTAssertEqual(session.scene.presentation, .compact)
    }

    func testCaptionTickOnlyAdvancesWhilePlayingAndStopsAtEnd() async {
        let session = CaptionExperience()
        let initialID = session.scene.sceneID

        await session.handle(.tick(Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(session.scene.sceneID, initialID)

        await session.handle(.tap)
        await session.handle(.tick(Date(timeIntervalSince1970: 1)))
        await session.handle(.tick(Date(timeIntervalSince1970: 2)))
        await session.handle(.tick(Date(timeIntervalSince1970: 3)))

        XCTAssertEqual(session.primaryActionTitle, "播放字幕")
        XCTAssertEqual(text(for: "next", in: session.scene), "本地样例结束")
    }

    func testSystemStatusUsesInjectedClockAndBoundaryEventsAreStable() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SystemStatusExperience(now: { date })
        let displayedTime = text(for: "value", in: session.scene)
        let initialRevision = session.scene.revision

        XCTAssertEqual(displayedTime, date.formatted(date: .omitted, time: .shortened))
        await session.handle(.swipeUp)
        XCTAssertEqual(session.scene.revision, initialRevision)
    }

    func testActivationAwaitsPreviousAndDestinationReset() async {
        let navigation = NavigationExperience()
        let caption = CaptionExperience()
        let navigationRevision = navigation.scene.revision
        let captionRevision = caption.scene.revision
        let runtime = ExperienceRuntime(sessions: [navigation, caption])

        await runtime.activate(.caption)

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertGreaterThan(navigation.scene.revision, navigationRevision)
        XCTAssertGreaterThan(caption.scene.revision, captionRevision)
    }

    func testRuntimePublishesSpontaneousSessionSnapshot() async {
        let session = StreamingExperience(kind: .navigation)
        let runtime = ExperienceRuntime(sessions: [session])

        session.emit(revision: 42, eventDescription: "background_update")
        await waitUntil { runtime.scene.revision == 42 }

        XCTAssertEqual(runtime.scene.sceneID, "stream_navigation")
        XCTAssertEqual(runtime.primaryActionTitle, "流式动作 42")
        XCTAssertEqual(runtime.lastEventDescription, "background_update")
    }

    func testRuntimePublishesExperienceControlStateWithoutConcreteControllerDependency() async {
        let session = StreamingExperience(kind: .conversation)
        let runtime = ExperienceRuntime(sessions: [session])
        let controlState = ExperienceControlState(
            statusTitle: "正在思考",
            statusDetail: "核心功能提供的通用状态",
            errorMessage: nil,
            primaryActionSystemImage: "ellipsis",
            allowsPrimaryAction: false
        )

        session.emit(
            revision: 7,
            eventDescription: "control_state_update",
            controlState: controlState
        )
        await waitUntil { runtime.controlState == controlState }

        XCTAssertEqual(runtime.controlState, controlState)
        XCTAssertEqual(runtime.scene.revision, 7)
        XCTAssertEqual(runtime.lastEventDescription, "control_state_update")
    }

    func testRuntimePublishesControlOnlySnapshotWhenSceneIsUnchanged() async {
        let session = StreamingExperience(kind: .conversation)
        let runtime = ExperienceRuntime(sessions: [session])
        let unchangedScene = runtime.scene
        let controlState = ExperienceControlState(
            statusTitle: "控制状态已改变",
            statusDetail: "HUD 场景无需变化",
            errorMessage: nil,
            primaryActionSystemImage: "stop.fill",
            allowsPrimaryAction: true
        )

        session.emitSnapshot(ExperienceSnapshot(
            scene: unchangedScene,
            primaryActionTitle: "结束说话",
            eventDescription: "control_only_update",
            controlState: controlState
        ))
        await waitUntil { runtime.controlState == controlState }

        XCTAssertEqual(runtime.scene, unchangedScene)
        XCTAssertEqual(runtime.primaryActionTitle, "结束说话")
        XCTAssertEqual(runtime.lastEventDescription, "control_only_update")
    }

    func testRuntimeNewestSnapshotKeepsCompleteCumulativeStreamingPrefix() async {
        let session = StreamingExperience(kind: .navigation)
        let runtime = ExperienceRuntime(sessions: [session])
        var cumulative = ""

        for revision in 1...100 {
            cumulative += "字"
            session.emit(
                revision: revision,
                eventDescription: "delta_\(revision)",
                flowingText: cumulative
            )
        }
        await waitUntil { runtime.scene.revision == 100 }

        guard let element = runtime.scene.elements.first,
              case .flowingText(let text, let isStreaming, _) = element.content else {
            return XCTFail("最新快照应包含累计流式文本")
        }
        XCTAssertEqual(text, String(repeating: "字", count: 100))
        XCTAssertTrue(isStreaming)
        XCTAssertEqual(runtime.lastEventDescription, "delta_100")
    }

    func testOldAsyncEventCannotPublishAfterExperienceSwitch() async {
        let oldSession = SuspendedExperience(kind: .navigation)
        let destination = StreamingExperience(kind: .caption)
        let runtime = ExperienceRuntime(sessions: [oldSession, destination])
        let destinationSceneID = destination.scene.sceneID

        let oldEvent = Task { await runtime.handle(.tap) }
        await waitUntil { oldSession.isHandling }
        await runtime.activate(.caption)
        oldSession.complete()
        await oldEvent.value

        XCTAssertEqual(runtime.selectedKind, .caption)
        XCTAssertEqual(runtime.scene.sceneID, destinationSceneID)
        XCTAssertEqual(runtime.lastEventDescription, "activate_caption")
    }

    func testEveryBuiltInSceneElementStaysInsideNormalizedSafeArea() async {
        let sessions: [any ExperienceSession] = [
            SystemStatusExperience(), NavigationExperience(), NotificationExperience(),
            CaptionExperience()
        ]

        for session in sessions {
            for element in session.scene.elements {
                XCTAssertGreaterThanOrEqual(element.frame.x, 0, session.kind.rawValue)
                XCTAssertGreaterThanOrEqual(element.frame.y, 0, session.kind.rawValue)
                XCTAssertGreaterThan(element.frame.width, 0, session.kind.rawValue)
                XCTAssertGreaterThan(element.frame.height, 0, session.kind.rawValue)
                XCTAssertLessThanOrEqual(element.frame.x + element.frame.width, 1, session.kind.rawValue)
                XCTAssertLessThanOrEqual(element.frame.y + element.frame.height, 1, session.kind.rawValue)
            }
        }
    }

    private func progress(in scene: HUDScene) -> Double? {
        for element in scene.elements {
            if case let .progress(value) = element.content { return value }
        }
        return nil
    }

    private func text(for id: String, in scene: HUDScene) -> String? {
        guard let element = scene.elements.first(where: { $0.id == id }),
              case let .text(value, _) = element.content else {
            return nil
        }
        return value
    }

    private func waitUntil(
        iterations: Int = 500,
        _ predicate: @MainActor () -> Bool
    ) async {
        for _ in 0..<iterations {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("等待异步状态超时")
    }
}

@MainActor
private final class StreamingExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    private(set) var scene: HUDScene
    private(set) var primaryActionTitle = "流式动作 0"

    private let stream: AsyncStream<ExperienceUpdate>
    private let continuation: AsyncStream<ExperienceUpdate>.Continuation

    init(kind: ExperienceKind) {
        self.descriptor = testDescriptor(kind: kind)
        self.scene = HUDScene(
            sceneID: "stream_\(kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
        let (stream, continuation) = AsyncStream<ExperienceUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func updates() -> AsyncStream<ExperienceUpdate> { stream }
    func handle(_ event: DemoEvent) async {}
    func reset() async {}

    func emit(
        revision: Int,
        eventDescription: String,
        flowingText: String? = nil,
        controlState: ExperienceControlState? = nil
    ) {
        scene = HUDScene(
            sceneID: "stream_\(kind.rawValue)",
            revision: revision,
            presentation: .focused,
            elements: flowingText.map {
                [HUDElement(
                    id: "streaming_answer",
                    frame: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                    content: .flowingText($0, isStreaming: true, footer: nil)
                )]
            } ?? []
        )
        primaryActionTitle = "流式动作 \(revision)"
        continuation.yield(ExperienceUpdateSource.spontaneous(ExperienceSnapshot(
            scene: scene,
            primaryActionTitle: primaryActionTitle,
            eventDescription: eventDescription,
            controlState: controlState
        )))
    }

    func emitSnapshot(_ snapshot: ExperienceSnapshot) {
        scene = snapshot.scene
        primaryActionTitle = snapshot.primaryActionTitle
        continuation.yield(ExperienceUpdateSource.spontaneous(snapshot))
    }
}

@MainActor
private final class SuspendedExperience: ExperienceSession {
    let descriptor: ExperienceDescriptor
    private(set) var scene: HUDScene
    let primaryActionTitle = "等待"
    private(set) var isHandling = false
    private var pending: CheckedContinuation<Void, Never>?

    init(kind: ExperienceKind) {
        self.descriptor = testDescriptor(kind: kind)
        self.scene = HUDScene(
            sceneID: "suspended_\(kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
    }

    func handle(_ event: DemoEvent) async {
        isHandling = true
        await withCheckedContinuation { continuation in
            pending = continuation
        }
        scene = HUDScene(
            sceneID: "stale_\(kind.rawValue)",
            revision: 99,
            presentation: .result,
            elements: []
        )
    }

    func reset() async {}

    func complete() {
        pending?.resume()
        pending = nil
    }
}

@MainActor
private final class NonFinishingObservationExperience: ExperienceSession {
    let descriptor = testDescriptor(kind: .caption)
    let scene = HUDScene(
        sceneID: "non_finishing",
        revision: 0,
        presentation: .compact,
        elements: []
    )
    let primaryActionTitle = "Observe"
    private(set) var hasSubscriber = false
    private(set) var wasTerminated = false
    private(set) var shutdownCount = 0

    func updates() -> AsyncStream<ExperienceUpdate> {
        hasSubscriber = true
        let observer = self
        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task { @MainActor in
                    observer.wasTerminated = true
                }
            }
        }
    }

    func handle(_ event: DemoEvent) async {}
    func reset() async {}
    func shutdown() async { shutdownCount += 1 }
}

private func testDescriptor(kind: ExperienceKind) -> ExperienceDescriptor {
    ExperienceDescriptor(
        kind: kind,
        displayName: "Test \(kind.rawValue)",
        detail: "Deterministic test fixture",
        systemImageName: "testtube.2",
        actions: [
            ExperienceActionDescriptor(
                id: BuiltInExperienceActions.primaryID,
                event: .tap,
                placement: .primary,
                titleSource: .snapshotPrimaryAction,
                iconSource: .fixed("hand.tap"),
                accessibilityLabel: "Run test action"
            )
        ]
    )
}
