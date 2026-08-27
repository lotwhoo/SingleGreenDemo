import CoreGraphics
import XCTest
@testable import SingleGreenCore

@MainActor
final class SingleGreenCoreTests: XCTestCase {
    func testRuntimeDefaultsToSystemStatusAndRegistersAllExperiences() async {
        let runtime = ExperienceRuntime()

        XCTAssertEqual(runtime.selectedKind, .systemStatus)
        XCTAssertEqual(runtime.availableKinds, [.systemStatus, .navigation, .notification, .caption])
        XCTAssertEqual(runtime.scene.presentation, .compact)
    }

    func testRuntimeRejectsDuplicateKindsWithoutCrashing() async {
        let runtime = ExperienceRuntime(sessions: [NavigationExperience(), NavigationExperience()])

        XCTAssertEqual(runtime.availableKinds, [.navigation])
        XCTAssertEqual(runtime.rejectedDuplicateKinds, [.navigation])
        XCTAssertEqual(runtime.lastEventDescription, "duplicate_experience_navigation")
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

        await session.handle(.tap)
        XCTAssertEqual(session.scene.revision, initialRevision)

        await session.handle(.triggerAlert)
        XCTAssertEqual(session.scene.presentation, .alert)
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

    func testNormalizedRectMapsIntoBounds() async {
        let normalized = NormalizedRect(x: 0.25, y: 0.10, width: 0.50, height: 0.40)
        let result = normalized.rect(in: CGRect(x: 10, y: 20, width: 200, height: 100))

        XCTAssertEqual(result, CGRect(x: 60, y: 30, width: 100, height: 40))
    }

    func testNormalizedInsetsScaleRelativeToRect() async {
        let result = NormalizedInsets(horizontal: 0.10, vertical: 0.20)
            .inset(CGRect(x: 0, y: 0, width: 200, height: 100))

        XCTAssertEqual(result, CGRect(x: 20, y: 20, width: 160, height: 60))
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
    let kind: ExperienceKind
    private(set) var scene: HUDScene
    private(set) var primaryActionTitle = "流式动作 0"

    private let stream: AsyncStream<ExperienceSnapshot>
    private let continuation: AsyncStream<ExperienceSnapshot>.Continuation

    init(kind: ExperienceKind) {
        self.kind = kind
        self.scene = HUDScene(
            sceneID: "stream_\(kind.rawValue)",
            revision: 0,
            presentation: .compact,
            elements: []
        )
        let (stream, continuation) = AsyncStream<ExperienceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.stream = stream
        self.continuation = continuation
    }

    func updates() -> AsyncStream<ExperienceSnapshot> { stream }
    func handle(_ event: DemoEvent) async {}
    func reset() async {}

    func emit(revision: Int, eventDescription: String) {
        scene = HUDScene(
            sceneID: "stream_\(kind.rawValue)",
            revision: revision,
            presentation: .focused,
            elements: []
        )
        primaryActionTitle = "流式动作 \(revision)"
        continuation.yield(ExperienceSnapshot(
            scene: scene,
            primaryActionTitle: primaryActionTitle,
            eventDescription: eventDescription
        ))
    }
}

@MainActor
private final class SuspendedExperience: ExperienceSession {
    let kind: ExperienceKind
    private(set) var scene: HUDScene
    let primaryActionTitle = "等待"
    private(set) var isHandling = false
    private var pending: CheckedContinuation<Void, Never>?

    init(kind: ExperienceKind) {
        self.kind = kind
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
