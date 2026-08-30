import Combine
import Foundation
import StreamingTextKit

@MainActor
public final class TextAdventureController: ObservableObject {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias ReduceMotion = @MainActor @Sendable () -> Bool
    public typealias SeedGenerator = @MainActor @Sendable () -> UInt64

    @Published public private(set) var snapshot: ExperienceSnapshot
    public private(set) var state = TextAdventureState()

    private let provider: any TextAdventureTurnProvider
    private let preparationProvider: any TextAdventureRunPreparationProvider
    private let sleep: Sleep
    private let reduceMotion: ReduceMotion
    private let typewriterPolicy: TypewriterPolicy
    private let makeSeed: SeedGenerator
    private var sessionID = UUID()
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var textBuffer: TypewriterTextBuffer
    private var revision = 0
    private var isShutdown = false

    public init(
        provider: any TextAdventureTurnProvider,
        preparationProvider: any TextAdventureRunPreparationProvider = LocalTextAdventureRunPreparationProvider(),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        reduceMotion: @escaping ReduceMotion = { false },
        typewriterPolicy: TypewriterPolicy = TypewriterPolicy(
            tickIntervalMilliseconds: 220,
            shortBacklogLimit: 2_000,
            mediumBacklogLimit: 2_000,
            mediumBatchSize: 1,
            minimumLargeBatchSize: 1,
            catchUpTickBudget: 2_000
        ),
        seedGenerator: @escaping SeedGenerator = {
            UInt64.random(in: UInt64.min...UInt64.max)
        }
    ) {
        self.provider = provider
        self.preparationProvider = preparationProvider
        self.sleep = sleep
        self.reduceMotion = reduceMotion
        self.typewriterPolicy = typewriterPolicy
        self.makeSeed = seedGenerator
        self.textBuffer = TypewriterTextBuffer(policy: typewriterPolicy)
        self.snapshot = ExperienceSnapshot(
            scene: TextAdventureHUDMapper.scene(
                for: TextAdventureState(),
                visibleNarrative: "",
                revision: 0
            ),
            primaryActionTitle: "开始游戏",
            eventDescription: "text_adventure_idle"
        )
    }

    public func handle(_ direction: TextAdventureDirection) {
        guard !isShutdown else { return }
        switch direction {
        case .up:
            apply(.showRecap, eventDescription: "text_adventure_recap")
        case .down:
            apply(.showStatus, eventDescription: "text_adventure_status")
        case .left:
            choose(.a)
        case .right:
            if state.phase == .idle || state.phase == .ending {
                startNewGame()
            } else {
                choose(.b)
            }
        }
    }

    public func reset() {
        guard !isShutdown else { return }
        invalidateOperations()
        _ = try? TextAdventureReducer.reduce(state: &state, event: .reset)
        textBuffer.reset()
        publish(eventDescription: "text_adventure_reset")
    }

    public func updateHostLifecycle(_ lifecycle: ExperienceHostLifecycleState) {
        guard !isShutdown, lifecycle == .background else { return }
        let request = requestTask
        let preparation = preparationTask
        let display = displayTask
        guard request != nil || preparation != nil || display != nil else { return }

        generation += 1
        requestTask = nil
        preparationTask = nil
        displayTask = nil
        request?.cancel()
        preparation?.cancel()
        display?.cancel()

        if state.phase == .searchingInspiration || state.phase == .generatingFramework {
            _ = try? TextAdventureReducer.reduce(state: &state, event: .preparationFailed)
            textBuffer.reset()
        } else if state.isRequestInFlight {
            _ = try? TextAdventureReducer.reduce(state: &state, event: .requestFailed)
        } else if !textBuffer.isCaughtUp {
            textBuffer.flush()
        }
        publish(eventDescription: "text_adventure_background")

        let previousCleanup = lifecycleTask
        lifecycleTask = Task {
            await previousCleanup?.value
            await request?.value
            await preparation?.value
            await display?.value
        }
    }

    public func waitForPendingHostLifecycleTransition() async {
        await lifecycleTask?.value
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        generation += 1
        let request = requestTask
        let preparation = preparationTask
        let display = displayTask
        let lifecycle = lifecycleTask
        requestTask = nil
        preparationTask = nil
        displayTask = nil
        lifecycleTask = nil
        request?.cancel()
        preparation?.cancel()
        display?.cancel()
        await request?.value
        await preparation?.value
        await display?.value
        await lifecycle?.value
    }

    private func startNewGame() {
        let previousSeed = state.storyBrief?.seed
        invalidateOperations()
        sessionID = UUID()
        var seed = makeSeed()
        if seed == previousSeed {
            seed &+= 1
        }
        _ = try? TextAdventureReducer.reduce(state: &state, event: .beginPreparation(seed))
        textBuffer.reset()
        publish(eventDescription: "text_adventure_searching_inspiration")
        startPreparation(seed: seed)
    }

    private func startPreparation(seed: UInt64) {
        let expectedGeneration = generation
        let expectedSessionID = sessionID
        let trendRequest = TextAdventureTrendPreparationRequest(
            sessionID: expectedSessionID,
            seed: seed
        )
        preparationTask = Task { [weak self, preparationProvider] in
            do {
                let trend = try await preparationProvider.prepareTrendSeed(trendRequest)
                try Task.checkCancellation()
                guard let self,
                      self.isCurrent(
                        generation: expectedGeneration,
                        sessionID: expectedSessionID
                      ) else { return }
                self.advanceToFrameworkGeneration()
                let prepared = try await preparationProvider.prepareFramework(
                    TextAdventureFrameworkPreparationRequest(
                        sessionID: expectedSessionID,
                        seed: seed,
                        trendSeed: trend
                    )
                )
                try Task.checkCancellation()
                self.completePreparation(
                    prepared,
                    generation: expectedGeneration,
                    sessionID: expectedSessionID
                )
            } catch {
                self?.failPreparation(
                    generation: expectedGeneration,
                    sessionID: expectedSessionID
                )
            }
        }
    }

    private func advanceToFrameworkGeneration() {
        _ = try? TextAdventureReducer.reduce(state: &state, event: .beginFrameworkGeneration)
        publish(eventDescription: "text_adventure_generating_framework")
    }

    private func completePreparation(
        _ prepared: TextAdventurePreparedRun,
        generation expectedGeneration: Int,
        sessionID expectedSessionID: UUID
    ) {
        guard isCurrent(generation: expectedGeneration, sessionID: expectedSessionID) else { return }
        do {
            try TextAdventureReducer.reduce(state: &state, event: .preparationSucceeded(prepared))
        } catch {
            failPreparation(generation: expectedGeneration, sessionID: expectedSessionID)
            return
        }
        preparationTask = nil
        beginDisplayingCurrentNarrative()
        publish(eventDescription: "text_adventure_framework_ready")
    }

    private func failPreparation(
        generation expectedGeneration: Int,
        sessionID expectedSessionID: UUID
    ) {
        guard isCurrent(generation: expectedGeneration, sessionID: expectedSessionID) else { return }
        preparationTask = nil
        _ = try? TextAdventureReducer.reduce(state: &state, event: .preparationFailed)
        textBuffer.reset()
        publish(eventDescription: "text_adventure_preparation_failed")
    }

    private func choose(_ choice: TextAdventureChoice) {
        guard textBuffer.isCaughtUp else { return }
        guard let effects = try? TextAdventureReducer.reduce(
            state: &state,
            event: .choose(choice)
        ) else { return }
        publish(eventDescription: "text_adventure_choice_\(choice.rawValue)")
        guard case .request(let brief, let checkpoint, let selectedChoice) = effects.first(where: {
            if case .request = $0 { return true }
            return false
        }) else { return }
        startRequest(brief: brief, checkpoint: checkpoint, choice: selectedChoice)
    }

    private func startRequest(
        brief: TextAdventureStoryBrief,
        checkpoint: TextAdventureCheckpoint,
        choice: TextAdventureChoice
    ) {
        generation += 1
        let expectedGeneration = generation
        let expectedSessionID = sessionID
        let request = TextAdventureTurnRequest(
            sessionID: expectedSessionID,
            storyBrief: brief,
            checkpoint: checkpoint,
            choice: choice
        )
        requestTask = Task { [weak self, provider] in
            do {
                let proposal = try await provider.proposeTurn(request)
                try Task.checkCancellation()
                self?.completeRequest(
                    proposal,
                    generation: expectedGeneration,
                    sessionID: expectedSessionID
                )
            } catch {
                self?.failRequest(
                    generation: expectedGeneration,
                    sessionID: expectedSessionID
                )
            }
        }
    }

    private func completeRequest(
        _ proposal: TextAdventureCheckpoint,
        generation expectedGeneration: Int,
        sessionID expectedSessionID: UUID
    ) {
        guard isCurrent(generation: expectedGeneration, sessionID: expectedSessionID) else { return }
        do {
            try TextAdventureReducer.reduce(state: &state, event: .requestSucceeded(proposal))
        } catch {
            failRequest(generation: expectedGeneration, sessionID: expectedSessionID)
            return
        }
        requestTask = nil
        beginDisplayingCurrentNarrative()
        publish(eventDescription: "text_adventure_turn_\(proposal.turn)")
    }

    private func failRequest(generation expectedGeneration: Int, sessionID expectedSessionID: UUID) {
        guard isCurrent(generation: expectedGeneration, sessionID: expectedSessionID) else { return }
        requestTask = nil
        _ = try? TextAdventureReducer.reduce(state: &state, event: .requestFailed)
        publish(eventDescription: "text_adventure_request_failed")
    }

    private func apply(_ event: TextAdventureReducerEvent, eventDescription: String) {
        let previous = state
        _ = try? TextAdventureReducer.reduce(state: &state, event: event)
        guard state != previous else { return }
        publish(eventDescription: eventDescription)
    }

    private func beginDisplayingCurrentNarrative() {
        displayTask?.cancel()
        textBuffer.reset()
        guard let checkpoint = state.checkpoint else { return }
        textBuffer.append(checkpoint.narrative)
        if reduceMotion() {
            textBuffer.flush()
            return
        }
        generation += 1
        let expectedGeneration = generation
        let expectedSessionID = sessionID
        let interval = Duration.milliseconds(typewriterPolicy.tickIntervalMilliseconds)
        displayTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let self,
                      self.isCurrent(
                        generation: expectedGeneration,
                        sessionID: expectedSessionID
                      ) else { return }
                let batch = self.textBuffer.suggestedBatchSize()
                guard batch > 0 else {
                    self.displayTask = nil
                    return
                }
                if self.textBuffer.advance(maxCharacters: batch) {
                    self.publish(eventDescription: "text_adventure_typing")
                }
            }
        }
    }

    private func invalidateOperations() {
        generation += 1
        requestTask?.cancel()
        preparationTask?.cancel()
        displayTask?.cancel()
        requestTask = nil
        preparationTask = nil
        displayTask = nil
    }

    private func isCurrent(generation expectedGeneration: Int, sessionID expectedSessionID: UUID) -> Bool {
        !isShutdown && generation == expectedGeneration && sessionID == expectedSessionID
    }

    private func publish(eventDescription: String) {
        revision += 1
        let scene = TextAdventureHUDMapper.scene(
            for: state,
            visibleNarrative: textBuffer.visibleText,
            revision: revision
        )
        let actionTitle = switch state.phase {
        case .idle: "开始游戏"
        case .searchingInspiration: "正在搜索"
        case .generatingFramework: "正在生成"
        case .playing:
            state.isRequestInFlight || !textBuffer.isCaughtUp ? "正在接收" : "选择路线"
        case .ending: "重新开始"
        }
        snapshot = ExperienceSnapshot(
            scene: scene,
            primaryActionTitle: actionTitle,
            eventDescription: eventDescription,
            controlState: ExperienceControlState(
                statusTitle: actionTitle,
                statusDetail: "← A  → B  ↑ 回顾  ↓ 状态",
                errorMessage: state.userSafeError,
                primaryActionSystemImage: "gamecontroller",
                allowsPrimaryAction: state.phase == .idle
                    || state.phase == .ending
                    || (state.phase == .playing
                        && !state.isRequestInFlight
                        && textBuffer.isCaughtUp)
            )
        )
    }
}
