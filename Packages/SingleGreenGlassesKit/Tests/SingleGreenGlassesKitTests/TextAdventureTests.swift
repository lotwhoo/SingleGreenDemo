import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class TextAdventureTests: XCTestCase {
    func testTrendSeedRejectsRawOrUnsafeSearchMaterial() throws {
        XCTAssertNoThrow(try makeTrend())
        XCTAssertThrowsError(try makeTrend(theme: "https://example.com/story")) {
            XCTAssertEqual($0 as? TextAdventureValidationError, .invalidTrendSeed)
        }
        XCTAssertThrowsError(try makeTrend(theme: "《某热门短剧》续集")) {
            XCTAssertEqual($0 as? TextAdventureValidationError, .invalidTrendSeed)
        }
        XCTAssertThrowsError(try makeTrend(theme: "未成年医疗灾难")) {
            XCTAssertEqual($0 as? TextAdventureValidationError, .invalidTrendSeed)
        }
    }

    func testCheckpointUsesExactlyTwoBoundedSentencesAndCharacterSafety() throws {
        let checkpoint = try makeCheckpoint(turn: 1)
        XCTAssertEqual(checkpoint.narrative, "绿灯在雨里闪了两次。门后的脚步忽然停住。")
        XCTAssertThrowsError(try makeCheckpoint(turn: 1, narrative: "只有一句完整的话。"))
        XCTAssertThrowsError(try makeCheckpoint(
            turn: 1,
            narrative: "绿灯在雨里闪了两次。\n门后的脚步忽然停住。"
        )) {
            XCTAssertEqual(
                $0 as? TextAdventureValidationError,
                .narrativeContainsLineBreakOrControl
            )
        }
        XCTAssertThrowsError(try makeCheckpoint(turn: 1, choiceA: "短")) {
            XCTAssertEqual($0 as? TextAdventureValidationError, .invalidChoiceLabel)
        }
    }

    func testCheckpointRejectsDisplayUnsafeChoiceOnEitherSide() {
        let unsafeChoices = [
            "**前进**",
            "www.x",
            "向前走🚶",
            "向前\n走"
        ]

        for choice in unsafeChoices {
            XCTAssertThrowsError(try makeCheckpoint(turn: 1, choiceA: choice)) {
                XCTAssertEqual($0 as? TextAdventureValidationError, .invalidChoiceLabel)
            }
            XCTAssertThrowsError(try makeCheckpoint(turn: 1, choiceB: choice)) {
                XCTAssertEqual($0 as? TextAdventureValidationError, .invalidChoiceLabel)
            }
        }
    }

    func testReducerCommitsOnlyPreparedRunThenKeepsFrameworkImmutable() throws {
        let seed: UInt64 = 42
        let prepared = try makePreparedRun(seed: seed)
        var state = TextAdventureState()
        XCTAssertEqual(
            try TextAdventureReducer.reduce(state: &state, event: .beginPreparation(seed)),
            [.cancelRequest]
        )
        _ = try TextAdventureReducer.reduce(state: &state, event: .beginFrameworkGeneration)
        _ = try TextAdventureReducer.reduce(state: &state, event: .preparationSucceeded(prepared))
        XCTAssertEqual(state.phase, .playing)
        XCTAssertEqual(state.storyBrief, prepared.storyBrief)
        let checkpoint = try XCTUnwrap(state.checkpoint)
        XCTAssertEqual(
            try TextAdventureReducer.reduce(state: &state, event: .choose(.a)),
            [.request(prepared.storyBrief, checkpoint, .a)]
        )
        _ = try TextAdventureReducer.reduce(state: &state, event: .requestFailed)
        XCTAssertEqual(state.storyBrief, prepared.storyBrief)
        XCTAssertEqual(state.checkpoint, checkpoint)
    }

    func testReducerRejectsFrameworkWithWrongSeedWithoutMutation() throws {
        var state = TextAdventureState()
        _ = try TextAdventureReducer.reduce(state: &state, event: .beginPreparation(7))
        _ = try TextAdventureReducer.reduce(state: &state, event: .beginFrameworkGeneration)
        let before = state
        XCTAssertThrowsError(
            try TextAdventureReducer.reduce(
                state: &state,
                event: .preparationSucceeded(try makePreparedRun(seed: 8))
            )
        ) {
            XCTAssertEqual($0 as? TextAdventureValidationError, .preparationSeedMismatch)
        }
        XCTAssertEqual(state, before)
    }

    func testControllerRunsTrendThenFrameworkBeforeAcceptingControls() async {
        let preparation = ImmediatePreparationProvider()
        let turns = BlockingTurnProvider()
        let controller = makeController(turns: turns, preparation: preparation)
        controller.handle(.right)
        controller.handle(.left)
        await waitUntil { controller.state.phase == .playing }
        XCTAssertEqual(preparation.events, ["trend", "framework"])
        XCTAssertTrue(turns.requests.isEmpty)
        controller.handle(.left)
        controller.handle(.right)
        await waitUntil { turns.requests.count == 1 }
        XCTAssertEqual(turns.requests.map(\.choice), [.a])
        XCTAssertEqual(turns.requests.first?.storyBrief, controller.state.storyBrief)
    }

    func testRestartAdvancesDeterministicDuplicateSeed() async throws {
        var turns = try (1..<TextAdventureLimits.minimumEndingTurn).map {
            Result<TextAdventureCheckpoint, Error>.success(try makeCheckpoint(turn: $0))
        }
        turns.append(.success(try makeCheckpoint(
            turn: TextAdventureLimits.minimumEndingTurn,
            choiceA: nil,
            choiceB: nil,
            outcome: .ended
        )))
        let preparation = ImmediatePreparationProvider()
        let controller = makeController(
            turns: QueueTurnProvider(results: turns),
            preparation: preparation,
            seedGenerator: { 42 }
        )

        controller.handle(.right)
        await waitUntil { controller.state.phase == .playing }
        for turn in 1...TextAdventureLimits.minimumEndingTurn {
            controller.handle(.left)
            await waitUntil { controller.state.checkpoint?.turn == turn }
        }
        XCTAssertEqual(controller.state.phase, .ending)

        controller.handle(.right)
        await waitUntil {
            preparation.requestedSeeds.count == 2 && controller.state.phase == .playing
        }

        XCTAssertEqual(preparation.requestedSeeds, [42, 43])
        XCTAssertEqual(controller.state.storyBrief?.seed, 43)
    }

    func testConversationLifecycleAliasRemainsSourceCompatible() {
        let legacy: ConversationHostLifecycleState = .background
        let neutral: ExperienceHostLifecycleState = legacy
        XCTAssertEqual(neutral, .background)
    }

    func testUpAndDownNeverRequestOrMutateCanonicalRun() async {
        let preparation = ImmediatePreparationProvider()
        let turns = BlockingTurnProvider()
        let controller = makeController(turns: turns, preparation: preparation)
        controller.handle(.right)
        await waitUntil { controller.state.phase == .playing }
        let brief = controller.state.storyBrief
        let checkpoint = controller.state.checkpoint
        controller.handle(.up)
        XCTAssertEqual(controller.state.overlay, .recap)
        controller.handle(.down)
        XCTAssertEqual(controller.state.overlay, .status)
        XCTAssertEqual(controller.state.storyBrief, brief)
        XCTAssertEqual(controller.state.checkpoint, checkpoint)
        XCTAssertTrue(turns.requests.isEmpty)
        XCTAssertEqual(preparation.events, ["trend", "framework"])
    }

    func testResetRejectsStalePreparationCompletion() async throws {
        let preparation = BlockingPreparationProvider()
        let controller = makeController(turns: BlockingTurnProvider(), preparation: preparation)
        controller.handle(.right)
        await waitUntil { preparation.isWaiting }
        controller.reset()
        preparation.resumeTrend(with: try makeTrend())
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.state, TextAdventureState())
        XCTAssertEqual(preparation.frameworkRequestCount, 0)
    }

    func testResetRejectsStaleTurnCompletionByGeneration() async throws {
        let turns = LateTurnProvider()
        let controller = makeController(
            turns: turns,
            preparation: ImmediatePreparationProvider()
        )
        controller.handle(.right)
        await waitUntil { controller.state.phase == .playing }
        controller.handle(.left)
        await waitUntil { turns.isWaiting }
        controller.reset()
        turns.resume(with: try makeCheckpoint(turn: 1))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(controller.state, TextAdventureState())
    }

    func testBackgroundCancelsTurnAndRejectsLateCompletionWhilePreservingRun() async throws {
        let turns = LateTurnProvider()
        let controller = makeController(
            turns: turns,
            preparation: ImmediatePreparationProvider()
        )
        controller.handle(.right)
        await waitUntil { controller.state.phase == .playing }
        let opening = controller.state.checkpoint
        controller.handle(.left)
        await waitUntil { turns.isWaiting }

        controller.updateHostLifecycle(.background)
        XCTAssertEqual(controller.state.checkpoint, opening)
        XCTAssertFalse(controller.state.isRequestInFlight)

        turns.resume(with: try makeCheckpoint(turn: 1))
        await controller.waitForPendingHostLifecycleTransition()
        XCTAssertEqual(controller.state.checkpoint, opening)
        XCTAssertNotNil(controller.state.userSafeError)
    }

    func testFrameworkFailureFailsClosedBeforeGameplay() async {
        let preparation = ImmediatePreparationProvider(
            frameworkFailure: TextAdventureTestFailure.expected
        )
        let turns = BlockingTurnProvider()
        let controller = makeController(turns: turns, preparation: preparation)
        controller.handle(.right)
        await waitUntil { controller.state.userSafeError != nil }
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertNil(controller.state.storyBrief)
        XCTAssertNil(controller.state.checkpoint)
        XCTAssertTrue(turns.requests.isEmpty)
    }

    func testShutdownCancelsPreparation() async {
        let preparation = CancellationPreparationProvider()
        let controller = makeController(turns: BlockingTurnProvider(), preparation: preparation)
        controller.handle(.right)
        await Task.yield()
        await controller.shutdown()
        XCTAssertTrue(preparation.observedCancellation)
        XCTAssertNil(controller.state.storyBrief)
    }

    func testReduceMotionFlushesUnicodeNarrativeAtCharacterBoundaries() async throws {
        let proposal = try makeCheckpoint(
            turn: 1,
            narrative: "接收器浮出e\u{301}形波纹。门后的脚步忽然停住。"
        )
        let controller = makeController(
            turns: QueueTurnProvider(results: [.success(proposal)]),
            preparation: ImmediatePreparationProvider()
        )
        controller.handle(.right)
        await waitUntil { controller.state.phase == .playing }
        controller.handle(.left)
        await waitUntil { controller.state.checkpoint?.turn == 1 }
        XCTAssertEqual(storyText(in: controller.snapshot.scene), proposal.narrative)
        XCTAssertTrue(proposal.narrative.contains("e\u{301}"))
    }

    func testExperienceKeepsFourNamespacedControlsAndPreparationScene() {
        let controller = makeController(
            turns: QueueTurnProvider(results: []),
            preparation: BlockingPreparationProvider()
        )
        let experience = TextAdventureExperience(controller: controller)
        XCTAssertFalse(ExperienceKind.allCases.contains(experience.kind))
        XCTAssertEqual(experience.descriptor.actions.map(\.event), [
            TextAdventureExperience.leftAction,
            TextAdventureExperience.rightAction,
            TextAdventureExperience.upAction,
            TextAdventureExperience.downAction
        ])
        controller.handle(.right)
        XCTAssertEqual(controller.state.phase, .searchingInspiration)
        XCTAssertEqual(controller.snapshot.scene.sceneID, "text_adventure.green_signal")
        XCTAssertEqual(controller.snapshot.scene.elements.count, 3)
    }

    private func makeController(
        turns: any TextAdventureTurnProvider,
        preparation: any TextAdventureRunPreparationProvider,
        seedGenerator: @escaping TextAdventureController.SeedGenerator = { 42 }
    ) -> TextAdventureController {
        TextAdventureController(
            provider: turns,
            preparationProvider: preparation,
            reduceMotion: { true },
            seedGenerator: seedGenerator
        )
    }

    private func makeTrend(theme: String = "人与智能伙伴建立边界") throws -> TextAdventureTrendSeed {
        try TextAdventureTrendSeed(
            theme: theme,
            socialTension: "效率与自主选择之间的拉扯",
            emotionalQuestion: "信任应当由谁来证明",
            settingArchetype: "近未来公共空间",
            freshnessNote: "采用长期可用的科技生活议题"
        )
    }

    private func makePreparedRun(seed: UInt64) throws -> TextAdventurePreparedRun {
        let generated = GreenSignalStoryBriefGenerator.make(seed: seed)
        let brief = TextAdventureStoryBrief(
            seed: seed,
            genre: generated.genre,
            setting: generated.setting,
            protagonistRole: generated.protagonistRole,
            motif: generated.motif,
            pressure: generated.pressure,
            relationship: generated.relationship,
            plotStructure: generated.plotStructure,
            tone: generated.tone,
            trendSeed: try makeTrend()
        )
        return try TextAdventurePreparedRun(
            storyBrief: brief,
            openingCheckpoint: GreenSignalGame.initialCheckpoint(brief: brief)
        )
    }

    private func makeCheckpoint(
        turn: Int,
        narrative: String = "绿灯在雨里闪了两次。门后的脚步忽然停住。",
        choiceA: String? = "进入屋内",
        choiceB: String? = "绕到屋后",
        outcome: TextAdventureOutcome = .ongoing
    ) throws -> TextAdventureCheckpoint {
        try TextAdventureCheckpoint(
            turn: turn,
            narrative: narrative,
            recap: "你追踪信号来到巡山屋。",
            hint: "先确认退路。",
            status: try TextAdventureStatus(energy: 2, signal: 2, inventory: ["旧接收器"]),
            choiceA: choiceA,
            choiceB: choiceB,
            outcome: outcome
        )
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    private func storyText(in scene: HUDScene) -> String? {
        guard let element = scene.elements.first(where: { $0.id == "game_body" }) else { return nil }
        if case .styledFlowingText(let value, _, _, _) = element.content { return value }
        return nil
    }
}

private enum TextAdventureTestFailure: Error { case expected }

@MainActor
private final class ImmediatePreparationProvider: TextAdventureRunPreparationProvider {
    private(set) var events: [String] = []
    private(set) var requestedSeeds: [UInt64] = []
    private let frameworkFailure: Error?
    init(frameworkFailure: Error? = nil) { self.frameworkFailure = frameworkFailure }

    func prepareTrendSeed(_ request: TextAdventureTrendPreparationRequest) async throws
        -> TextAdventureTrendSeed {
        events.append("trend")
        requestedSeeds.append(request.seed)
        return .reviewedFallback(seed: request.seed)
    }

    func prepareFramework(_ request: TextAdventureFrameworkPreparationRequest) async throws
        -> TextAdventurePreparedRun {
        events.append("framework")
        if let frameworkFailure { throw frameworkFailure }
        let generated = GreenSignalStoryBriefGenerator.make(seed: request.seed)
        let brief = TextAdventureStoryBrief(
            seed: request.seed,
            genre: generated.genre,
            setting: generated.setting,
            protagonistRole: generated.protagonistRole,
            motif: generated.motif,
            pressure: generated.pressure,
            relationship: generated.relationship,
            plotStructure: generated.plotStructure,
            tone: generated.tone,
            trendSeed: request.trendSeed
        )
        return try TextAdventurePreparedRun(
            storyBrief: brief,
            openingCheckpoint: GreenSignalGame.initialCheckpoint(brief: brief)
        )
    }
}

@MainActor
private final class BlockingPreparationProvider: TextAdventureRunPreparationProvider {
    private var continuation: CheckedContinuation<TextAdventureTrendSeed, Error>?
    private(set) var frameworkRequestCount = 0
    var isWaiting: Bool { continuation != nil }

    func prepareTrendSeed(_ request: TextAdventureTrendPreparationRequest) async throws
        -> TextAdventureTrendSeed {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func prepareFramework(_ request: TextAdventureFrameworkPreparationRequest) async throws
        -> TextAdventurePreparedRun {
        frameworkRequestCount += 1
        throw TextAdventureTestFailure.expected
    }

    func resumeTrend(with seed: TextAdventureTrendSeed) {
        let current = continuation
        continuation = nil
        current?.resume(returning: seed)
    }
}

@MainActor
private final class CancellationPreparationProvider: TextAdventureRunPreparationProvider {
    private(set) var observedCancellation = false
    func prepareTrendSeed(_ request: TextAdventureTrendPreparationRequest) async throws
        -> TextAdventureTrendSeed {
        do {
            try await Task.sleep(for: .seconds(30))
            return .reviewedFallback(seed: request.seed)
        } catch {
            observedCancellation = true
            throw error
        }
    }
    func prepareFramework(_ request: TextAdventureFrameworkPreparationRequest) async throws
        -> TextAdventurePreparedRun { throw TextAdventureTestFailure.expected }
}

@MainActor
private final class BlockingTurnProvider: TextAdventureTurnProvider {
    private(set) var requests: [TextAdventureTurnRequest] = []
    func proposeTurn(_ request: TextAdventureTurnRequest) async throws -> TextAdventureCheckpoint {
        requests.append(request)
        try await Task.sleep(for: .seconds(30))
        return request.checkpoint
    }
}

@MainActor
private final class QueueTurnProvider: TextAdventureTurnProvider {
    private var results: [Result<TextAdventureCheckpoint, Error>]
    init(results: [Result<TextAdventureCheckpoint, Error>]) { self.results = results }
    func proposeTurn(_ request: TextAdventureTurnRequest) async throws -> TextAdventureCheckpoint {
        try results.removeFirst().get()
    }
}

@MainActor
private final class LateTurnProvider: TextAdventureTurnProvider {
    private var continuation: CheckedContinuation<TextAdventureCheckpoint, Error>?
    var isWaiting: Bool { continuation != nil }
    func proposeTurn(_ request: TextAdventureTurnRequest) async throws -> TextAdventureCheckpoint {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resume(with checkpoint: TextAdventureCheckpoint) {
        let current = continuation
        continuation = nil
        current?.resume(returning: checkpoint)
    }
}
