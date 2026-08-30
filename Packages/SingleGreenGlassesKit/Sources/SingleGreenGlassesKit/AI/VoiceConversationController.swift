import Foundation
import VoiceChatDomain

public enum ExperienceHostLifecycleState: Equatable, Sendable {
    case active
    case background
}

public typealias ConversationHostLifecycleState = ExperienceHostLifecycleState

/// AI 对话用例编排。只依赖可替换的端口，不直接创建 ASR、LLM、权限或时钟实现。
@MainActor
public final class VoiceConversationController: ObservableObject {
    @Published public private(set) var conversation = ConversationState()
    @Published public private(set) var liveText = ""
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var lastError: String?
    @Published public private(set) var snapshot: ExperienceSnapshot

    private let dependencies: VoiceConversationDependencies
    private let inputCoordinator: ConversationInputCoordinator
    private let displayScheduler: ConversationDisplayScheduler
    private let replyPipeline: ConversationReplyPipeline
    private let telemetryTracker: ConversationTelemetryTracker
    private var executionState = ConversationControllerExecutionState()
    private var lifecycleTasks: [Int: Task<Void, Never>] = [:]
    private var latestLifecycleTask: Task<Void, Never>?
    private var inputStartTaskGeneration = 0
    private var inputStartTasks: [Int: Task<Void, Never>] = [:]
    private var inputFinishTaskGeneration = 0
    private var inputFinishTasks: [Int: Task<Void, Never>] = [:]
    private var resetTaskGeneration = 0
    private var resetTasks: [Int: Task<Void, Never>] = [:]
    private var automaticRearmTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    public init(
        dependencies: VoiceConversationDependencies,
        silenceThreshold: Float = 0.03,
        silenceTimeout: TimeInterval = 1.5
    ) {
        self.dependencies = dependencies
        // Retain the former tuning arguments for source compatibility. Local
        // endpointing now belongs exclusively to the voice-activated session.
        _ = silenceThreshold
        _ = silenceTimeout
        self.inputCoordinator = ConversationInputCoordinator()
        self.telemetryTracker = ConversationTelemetryTracker(
            sink: dependencies.observability.telemetry,
            monotonicNow: dependencies.observability.monotonicNow
        )
        self.displayScheduler = ConversationDisplayScheduler(
            policy: dependencies.presentation.streamingTextPolicy,
            sleep: dependencies.presentation.sleep,
            reduceMotion: dependencies.presentation.reduceMotion
        )
        self.replyPipeline = ConversationReplyPipeline()
        snapshot = ConversationLifecycleProjection.makeSnapshot(
            revision: 0,
            state: .idle,
            transcript: "",
            assistantReply: "",
            audioLevel: 0,
            error: nil
        )
        displayScheduler.onVisibleTextChanged = { [weak self] operation, text in
            self?.handleVisibleTextChanged(text, operation: operation)
        }
        let replyPipeline = self.replyPipeline
        displayScheduler.onCaughtUp = { [weak self, replyPipeline] operation in
            do {
                _ = try await replyPipeline.acknowledgeCompletion(for: operation) { [weak self] in
                    self?.acceptAcknowledgedReply(operation: operation) == true
                }
            } catch {
                guard replyPipeline.isCurrent(operation), let self else { return }
                self.failReplyContextAcknowledgement(operation: operation)
            }
        }
        replyPipeline.onEvent = { [weak self] event in
            try self?.handleReplyPipelineEvent(event)
        }
        inputCoordinator.onEvent = { [weak self] event in
            await self?.handleInputCoordinatorEvent(event)
        }
    }

    public var messages: [ChatMessage] { conversation.messages }
    public var scene: HUDScene { snapshot.scene }
    public var revision: Int { snapshot.scene.revision }

    public var transcript: String {
        ConversationLifecycleProjection.transcript(liveText: liveText, conversation: conversation)
    }

    public var assistantReply: String {
        ConversationLifecycleProjection.assistantReply(
            displayedReply: displayScheduler.visibleText,
            conversation: conversation
        )
    }

    public var state: VoiceConversationState {
        ConversationLifecycleProjection.voiceState(
            conversation: conversation,
            assistantReply: assistantReply,
            error: lastError
        )
    }

    public var primaryActionTitle: String {
        snapshot.primaryActionTitle
    }

    public var primaryActionSystemImage: String {
        snapshot.controlState?.primaryActionSystemImage ?? "waveform"
    }

    public var allowsPrimaryAction: Bool {
        snapshot.controlState?.allowsPrimaryAction ?? state.allowsPrimaryAction
    }

    public var lastEventDescription: String { snapshot.eventDescription }
    public var controlState: ExperienceControlState? { snapshot.controlState }

    public func toggleConversation() async {
        guard !executionState.isShutdown else { return }
        switch state {
        case .idle, .failed, .completed, .thinking, .searching, .streaming:
            await startListening(trigger: .explicit)
        case .armed, .listening:
            disableContinuousVoiceActivation()
            await stopRecognition()
        case .connecting, .recognizing:
            break
        }
    }

    /// Backgrounding discards incomplete input/reply/display work but preserves
    /// successfully committed conversation history.
    public func suspendForBackground() async {
        guard !executionState.isShutdown else { return }
        let transition = beginHostLifecycleTransition(.background)
        let task = scheduleHostLifecycleTransition(transition)
        await task.value
    }

    /// Captures scene changes synchronously, then serializes their asynchronous
    /// cleanup through a generation check. A delayed background task therefore
    /// cannot cancel work created after a newer foreground transition.
    public func updateHostLifecycle(_ state: ConversationHostLifecycleState) {
        guard !executionState.isShutdown else { return }
        let transition = beginHostLifecycleTransition(state)
        scheduleHostLifecycleTransition(transition)
    }

    public func waitForPendingHostLifecycleTransition() async {
        await latestLifecycleTask?.value
    }

    /// Foregrounding is intentionally passive. Input and network work resume only
    /// after a new explicit user action.
    public func resumeFromForeground() {
        updateHostLifecycle(.active)
    }

    public func resetConversation() async {
        guard !executionState.isShutdown else { return }
        resetTaskGeneration += 1
        let generation = resetTaskGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performResetConversation()
            self.resetTasks.removeValue(forKey: generation)
        }
        resetTasks[generation] = task
        await task.value
    }

    private func performResetConversation() async {
        guard !executionState.isShutdown else { return }
        disableContinuousVoiceActivation()
        let controllerOperation = beginConversationOperation()
        telemetryTracker.terminateActiveWork(outcome: .cancelled)
        let operation = await inputCoordinator.cancel()
        guard isCurrent(controllerOperation, requiresActiveHost: false),
              inputCoordinator.isCurrent(operation) else { return }
        await invalidatePendingReply()
        guard isCurrent(controllerOperation, requiresActiveHost: false),
              inputCoordinator.isCurrent(operation) else { return }
        await replyPipeline.clearContext()
        guard isCurrent(controllerOperation, requiresActiveHost: false),
              inputCoordinator.isCurrent(operation) else { return }
        conversation = ConversationState()
        displayScheduler.reset()
        liveText = ""
        audioLevel = 0
        lastError = nil
        refreshSnapshot()
    }

    /// Stops active input, reply, and display work before the owning host releases this controller.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        guard executionState.beginShutdown() else { return }
        let inputCancellation = inputCoordinator.reserveCancellation()
        let pendingLifecycleTasks = Array(lifecycleTasks.values)
        lifecycleTasks.removeAll()
        latestLifecycleTask = nil
        let pendingInputStartTasks = Array(inputStartTasks.values)
        inputStartTasks.removeAll()
        let pendingInputFinishTasks = Array(inputFinishTasks.values)
        inputFinishTasks.removeAll()
        let pendingResetTasks = Array(resetTasks.values)
        resetTasks.removeAll()
        let pendingAutomaticRearmTask = automaticRearmTask
        automaticRearmTask = nil
        for startTask in pendingInputStartTasks {
            startTask.cancel()
        }
        pendingAutomaticRearmTask?.cancel()
        telemetryTracker.terminateActiveWork(outcome: .cancelled)
        let replyCleanup = replyPipeline.beginInvalidation()
        _ = conversation.abortUncommittedTurn()
        displayScheduler.reset()
        conversation.inputState = .idle
        liveText = ""
        audioLevel = 0
        lastError = nil
        publishShutdownSnapshot()
        let task = Task { @MainActor [inputCoordinator, replyPipeline] in
            await inputCoordinator.completeCancellation(inputCancellation)
            for lifecycleTask in pendingLifecycleTasks {
                await lifecycleTask.value
            }
            for startTask in pendingInputStartTasks {
                await startTask.value
            }
            await pendingAutomaticRearmTask?.value
            for finishTask in pendingInputFinishTasks {
                await finishTask.value
            }
            for resetTask in pendingResetTasks {
                await resetTask.value
            }
            await inputCoordinator.drainCleanup()
            await replyCleanup.value
            await replyPipeline.clearContext()
        }
        shutdownTask = task
        await task.value
    }

    private func startListening(trigger: VoiceInputStartTrigger) async {
        guard !executionState.isShutdown else { return }
        inputStartTaskGeneration += 1
        let generation = inputStartTaskGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStartListening(trigger: trigger)
            self.inputStartTasks.removeValue(forKey: generation)
        }
        inputStartTasks[generation] = task
        await task.value
    }

    private func performStartListening(trigger: VoiceInputStartTrigger) async {
        guard !executionState.isShutdown else { return }
        switch trigger {
        case .explicit:
            disableContinuousVoiceActivation()
        case .automatic(let generation):
            guard isContinuousVoiceActivationCurrent(generation), state == .completed else { return }
        }
        guard state.allowsPrimaryAction, state != .listening else { return }
        let controllerOperation = beginConversationOperation()
        telemetryTracker.terminateActiveWork(outcome: .cancelled)
        await invalidatePendingReply()
        guard isCurrent(controllerOperation) else { return }
        let operation = await inputCoordinator.beginStart()
        guard isCurrent(controllerOperation), inputCoordinator.isCurrent(operation) else { return }

        telemetryTracker.begin(.input)
        let inputMode = dependencies.input.inputMode()
        let continuousGeneration: Int?
        switch trigger {
        case .explicit:
            continuousGeneration = inputMode == .voiceActivated
                ? beginContinuousVoiceActivation()
                : nil
        case .automatic(let generation):
            guard inputMode == .voiceActivated,
                  isContinuousVoiceActivationCurrent(generation) else {
                disableContinuousVoiceActivation()
                telemetryTracker.recordIfActive(.input, outcome: .cancelled)
                return
            }
            continuousGeneration = generation
        }
        guard inputMode != .voiceActivated
                || dependencies.input.voiceActivatedInputAvailable() else {
            disableContinuousVoiceActivation()
            await inputCoordinator.fail(
                dependencies.presentation.copy.voiceActivatedUnavailable,
                failureCode: .configurationMissing
            )
            return
        }
        let preparedInput: PreparedSpeechInputSession
        telemetryTracker.begin(.preparation)
        do {
            preparedInput = try await dependencies.input.prepareSpeechInput(inputMode)
            guard isInputStartCurrent(
                controllerOperation,
                inputOperation: operation,
                continuousGeneration: continuousGeneration
            ) else {
                await preparedInput.cancel()
                return
            }
            guard preparedInput.mode == inputMode else {
                await preparedInput.cancel()
                telemetryTracker.recordIfActive(.preparation, outcome: .failed, failure: .protocolFailure)
                await inputCoordinator.fail(
                    dependencies.presentation.copy.speechRecognitionUnavailable,
                    failureCode: .protocolFailure
                )
                return
            }
            telemetryTracker.recordIfActive(.preparation, outcome: .succeeded)
        } catch {
            guard isInputStartCurrent(
                controllerOperation,
                inputOperation: operation,
                continuousGeneration: continuousGeneration
            ) else { return }
            let failure = error as? ConversationPreparationFailure
            telemetryTracker.recordIfActive(
                .preparation,
                outcome: .failed,
                failure: failure?.failureCode ?? .preparationUnavailable
            )
            await inputCoordinator.fail(
                failure?.userSafeMessage ?? dependencies.presentation.copy.speechRecognitionUnavailable,
                failureCode: failure?.failureCode ?? .preparationUnavailable
            )
            return
        }
        guard isInputStartCurrent(
            controllerOperation,
            inputOperation: operation,
            continuousGeneration: continuousGeneration
        ) else {
            await preparedInput.cancel()
            return
        }
        lastError = nil
        liveText = ""
        audioLevel = 0
        await inputCoordinator.start(
            operation: operation,
            preparedInput: preparedInput,
            requestPermission: { [dependencies] in
                await dependencies.input.requestMicrophonePermission()
            },
            copy: dependencies.presentation.copy
        )
    }

    private func stopRecognition() async {
        guard !executionState.isShutdown else { return }
        inputFinishTaskGeneration += 1
        let generation = inputFinishTaskGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStopRecognition()
            self.inputFinishTasks.removeValue(forKey: generation)
        }
        inputFinishTasks[generation] = task
        await task.value
    }

    private func performStopRecognition() async {
        guard !executionState.isShutdown else { return }
        guard conversation.inputState == .armed || conversation.inputState == .recording else { return }
        await inputCoordinator.finishCurrent()
    }

    private func finishASRAndRequestReply(operation: InputOperation) async {
        guard inputCoordinator.isCurrent(operation) else { return }
        let controllerOperation = beginConversationOperation()
        conversation.inputState = .idle
        audioLevel = 0
        let finalText = liveText.trimmed
        liveText = ""
        guard !finalText.isEmpty else {
            disableContinuousVoiceActivation()
            lastError = dependencies.presentation.copy.noSpeech
            refreshSnapshot()
            return
        }

        await invalidatePendingReply()
        guard isCurrent(controllerOperation), inputCoordinator.isCurrent(operation) else { return }
        await requestReply(userText: finalText, controllerOperation: controllerOperation)
    }

    private func requestReply(
        userText: String,
        controllerOperation: Int
    ) async {
        guard isCurrent(controllerOperation) else { return }
        telemetryTracker.begin(.reply)
        let preparedAgent: PreparedConversationAgent
        telemetryTracker.begin(.preparation)
        do {
            preparedAgent = try await dependencies.agent.prepareAgent()
            guard isCurrent(controllerOperation) else {
                await preparedAgent.discard()
                return
            }
            telemetryTracker.recordIfActive(.preparation, outcome: .succeeded)
        } catch {
            guard isCurrent(controllerOperation) else { return }
            let failure = error as? ConversationPreparationFailure
            telemetryTracker.recordIfActive(
                .preparation,
                outcome: .failed,
                failure: failure?.failureCode ?? .preparationUnavailable
            )
            failReplyConfiguration(
                failure?.userSafeMessage ?? dependencies.presentation.copy.replyPreparationUnavailable,
                failureCode: failure?.failureCode ?? .preparationUnavailable
            )
            return
        }
        guard isCurrent(controllerOperation) else {
            await preparedAgent.discard()
            return
        }
        conversation.appendUser(userText)
        let replyID = conversation.beginReply()
        lastError = nil

        let operation = await replyPipeline.start(
            replyID: replyID,
            userText: userText,
            preparedAgent: preparedAgent,
            incompleteStreamMessage: dependencies.presentation.copy.incompleteReplyStream,
            unexpectedFailureMessage: dependencies.presentation.copy.unexpectedReplyFailure
        )
        guard isCurrent(controllerOperation), replyPipeline.isCurrent(operation) else { return }
        displayScheduler.begin(operation)
        telemetryTracker.begin(.display)
        refreshSnapshot()
    }

    private func failReplyConfiguration(
        _ message: String,
        failureCode: ConversationFailureCode
    ) {
        disableContinuousVoiceActivation()
        lastError = message
        conversation.inputState = .idle
        telemetryTracker.recordIfActive(.reply, outcome: .failed, failure: failureCode)
        refreshSnapshot()
    }

    private func markReplySearching(operation: ReplyOperation) {
        guard replyPipeline.isCurrent(operation) else { return }
        conversation.markSearching(id: operation.id)
        refreshSnapshot()
    }

    private func receiveReplyDelta(_ delta: String, operation: ReplyOperation) {
        guard replyPipeline.isCurrent(operation), !delta.isEmpty,
              conversation.appendReplyDelta(id: operation.id, delta: delta) else { return }
        displayScheduler.append(delta, for: operation)
    }

    private func receiveReplyCompletion(_ answer: String, operation: ReplyOperation) throws {
        guard replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id else { return }
        guard !answer.trimmed.isEmpty else {
            throw ConversationControllerError.invalidReply(dependencies.presentation.copy.emptyReply)
        }

        let accumulated = conversation.messages.first(where: { $0.id == operation.id })?.text ?? ""
        do {
            let suffix = try displayScheduler.reconcileAndMarkUpstreamCompleted(
                answer: answer,
                accumulated: accumulated,
                for: operation
            )
            if let suffix, !suffix.isEmpty {
                guard conversation.appendReplyDelta(id: operation.id, delta: suffix) else { return }
            }
        } catch ConversationDisplaySchedulerError.inconsistentStream {
            throw ConversationControllerError.invalidReply(
                dependencies.presentation.copy.inconsistentReplyStream
            )
        }
    }

    private func invalidatePendingReply() async {
        _ = conversation.cancelActiveReply()
        displayScheduler.reset()
        await replyPipeline.invalidate()
        telemetryTracker.recordIfActive(.display, outcome: .cancelled)
        telemetryTracker.recordIfActive(.reply, outcome: .cancelled)
    }

    private func handleVisibleTextChanged(_ text: String, operation: ReplyOperation) {
        guard !executionState.isShutdown,
              replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id else { return }
        refreshSnapshot()
    }

    private func acceptAcknowledgedReply(operation: ReplyOperation) -> Bool {
        guard !executionState.isShutdown,
              replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id,
              conversation.completeReply(id: operation.id) else { return false }
        lastError = nil
        telemetryTracker.recordIfActive(.display, outcome: .succeeded)
        telemetryTracker.recordIfActive(.reply, outcome: .succeeded)
        refreshSnapshot()
        scheduleAutomaticRearmIfNeeded()
        return true
    }

    private func failReplyContextAcknowledgement(operation: ReplyOperation) {
        guard !executionState.isShutdown,
              replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id,
              displayScheduler.settleFailure(
                discardPartial: false,
                for: operation
              )?.preservesPartial == true else { return }
        disableContinuousVoiceActivation()
        let message = dependencies.presentation.copy.contextCommitFailed
        _ = conversation.failReply(
            id: operation.id,
            message: message,
            preservingPartial: true
        )
        lastError = message
        telemetryTracker.recordIfActive(.display, outcome: .succeeded)
        telemetryTracker.recordIfActive(.reply, outcome: .failed, failure: .contextCommitFailed)
        refreshSnapshot()
    }

    private func handleReplyPipelineEvent(_ event: ReplyPipelineEvent) throws {
        guard !executionState.isShutdown else { return }
        switch event {
        case .searching(let operation):
            markReplySearching(operation: operation)
        case .delta(let operation, let delta):
            receiveReplyDelta(delta, operation: operation)
        case .completed(let operation, let answer):
            try receiveReplyCompletion(answer, operation: operation)
        case .failed(let operation, let failure):
            handleReplyFailure(failure, operation: operation)
        }
    }

    private func handleReplyFailure(
        _ failure: ReplyPipelineFailure,
        operation: ReplyOperation
    ) {
        guard replyPipeline.isCurrent(operation),
              let displayResult = displayScheduler.settleFailure(
                discardPartial: failure.shouldDiscardPartial,
                for: operation
              ) else { return }
        disableContinuousVoiceActivation()
        let hasPartialReply = displayResult.preservesPartial
        let prefix = hasPartialReply
            ? dependencies.presentation.copy.interruptedReplyPrefix
            : dependencies.presentation.copy.failedReplyPrefix
        let message = "\(prefix)\(failure.message)"
        _ = conversation.failReply(
            id: operation.id,
            message: message,
            preservingPartial: hasPartialReply
        )
        lastError = message
        telemetryTracker.recordIfActive(.display, outcome: .failed, failure: .interrupted)
        telemetryTracker.recordIfActive(.reply, outcome: .failed, failure: failure.failureCode)
        refreshSnapshot()
    }

    private func handleInputCoordinatorEvent(_ event: InputCoordinatorEvent) async {
        guard !executionState.isShutdown else { return }
        switch event {
        case .preparing(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            conversation.inputState = .preparing
            refreshSnapshot()
        case .armed(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            conversation.inputState = .armed
            refreshSnapshot()
        case .recording(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            conversation.inputState = .recording
            refreshSnapshot()
        case .finalizing(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            conversation.inputState = .finalizing
            refreshSnapshot()
        case .transcript(let operation, let text):
            guard inputCoordinator.isCurrent(operation) else { return }
            let normalized = text.trimmed
            if !normalized.isEmpty { liveText = normalized }
            refreshSnapshot()
        case .level(let operation, let value):
            guard inputCoordinator.isCurrent(operation) else { return }
            audioLevel = max(0, min(value, 1))
            refreshSnapshot()
        case .noSpeech(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            disableContinuousVoiceActivation()
            conversation.inputState = .idle
            liveText = ""
            audioLevel = 0
            lastError = nil
            telemetryTracker.recordIfActive(.input, outcome: .succeeded)
            refreshSnapshot()
        case .finished(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            telemetryTracker.recordIfActive(.input, outcome: .succeeded)
            await finishASRAndRequestReply(operation: operation)
        case .failed(let operation, let message, let failure):
            guard inputCoordinator.isCurrent(operation) else { return }
            disableContinuousVoiceActivation()
            audioLevel = 0
            liveText = ""
            lastError = message
            conversation.inputState = .failed(message)
            telemetryTracker.recordIfActive(.input, outcome: .failed, failure: failure)
            refreshSnapshot()
        }
    }

    private func refreshSnapshot() {
        guard !executionState.isShutdown else { return }
        let capturedState = state
        let capturedTranscript = transcript
        let capturedAssistantReply = assistantReply
        let capturedAudioLevel = audioLevel
        let capturedError = lastError
        snapshot = ConversationLifecycleProjection.makeSnapshot(
            revision: snapshot.scene.revision + 1,
            state: capturedState,
            transcript: capturedTranscript,
            assistantReply: capturedAssistantReply,
            audioLevel: capturedAudioLevel,
            error: capturedError
        )
    }

    private func publishShutdownSnapshot() {
        snapshot = ConversationLifecycleProjection.makeSnapshot(
            revision: snapshot.scene.revision + 1,
            state: state,
            transcript: transcript,
            assistantReply: assistantReply,
            audioLevel: audioLevel,
            error: lastError
        )
    }

    private func beginConversationOperation() -> Int {
        executionState.beginConversationOperation()
    }

    private func isCurrent(
        _ operation: Int,
        requiresActiveHost: Bool = true
    ) -> Bool {
        executionState.isConversationOperationCurrent(
            operation,
            requiresActiveHost: requiresActiveHost
        )
    }

    private func beginHostLifecycleTransition(
        _ state: ConversationHostLifecycleState
    ) -> HostLifecycleTransition {
        let executionTransition = executionState.beginHostLifecycleTransition(state)
        let inputCancellation = state == .background
            ? inputCoordinator.reserveCancellation()
            : nil
        let replyCleanup = state == .background
            ? replyPipeline.beginInvalidation()
            : nil
        if state == .background {
            cancelAutomaticRearmTask()
            telemetryTracker.terminateActiveWork(outcome: .suspended)
            _ = conversation.abortUncommittedTurn()
            displayScheduler.reset()
            conversation.inputState = .idle
            liveText = ""
            audioLevel = 0
            lastError = nil
            telemetryTracker.record(.lifecycle, outcome: .suspended)
            refreshSnapshot()
        }
        return HostLifecycleTransition(
            generation: executionTransition.generation,
            state: state,
            inputCancellation: inputCancellation,
            replyCleanup: replyCleanup
        )
    }

    @discardableResult
    private func scheduleHostLifecycleTransition(
        _ transition: HostLifecycleTransition
    ) -> Task<Void, Never> {
        let generation = transition.generation
        let task: Task<Void, Never>
        switch transition.state {
        case .background:
            let inputCoordinator = self.inputCoordinator
            let inputCancellation = transition.inputCancellation
            let replyCleanup = transition.replyCleanup
            task = Task { [weak self] in
                if let inputCancellation {
                    await inputCoordinator.completeCancellation(inputCancellation)
                }
                await replyCleanup?.value
                self?.lifecycleTasks.removeValue(forKey: generation)
            }
        case .active:
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.lifecycleTasks.removeValue(forKey: generation) }
                guard self.executionState.isHostLifecycleCurrent(generation) else { return }
                self.telemetryTracker.record(.lifecycle, outcome: .succeeded)
            }
        }
        lifecycleTasks[generation] = task
        latestLifecycleTask = task
        return task
    }

    private func beginContinuousVoiceActivation() -> Int {
        executionState.beginContinuousVoiceActivation()
    }

    private func disableContinuousVoiceActivation() {
        executionState.disableContinuousVoiceActivation()
        cancelAutomaticRearmTask()
    }

    private func cancelAutomaticRearmTask() {
        automaticRearmTask?.cancel()
        automaticRearmTask = nil
    }

    private func isContinuousVoiceActivationCurrent(_ generation: Int) -> Bool {
        executionState.isContinuousVoiceActivationCurrent(generation)
    }

    private func isInputStartCurrent(
        _ controllerOperation: Int,
        inputOperation: InputOperation,
        continuousGeneration: Int?
    ) -> Bool {
        guard isCurrent(controllerOperation), inputCoordinator.isCurrent(inputOperation) else {
            return false
        }
        guard let continuousGeneration else { return true }
        return isContinuousVoiceActivationCurrent(continuousGeneration)
    }

    private func scheduleAutomaticRearmIfNeeded() {
        guard !executionState.isShutdown,
              let generation = executionState.activeContinuousVoiceActivation,
              isContinuousVoiceActivationCurrent(generation) else { return }
        automaticRearmTask?.cancel()
        automaticRearmTask = Task { [weak self] in
            guard !Task.isCancelled, let self,
                  self.isContinuousVoiceActivationCurrent(generation) else { return }
            await self.startListening(trigger: .automatic(generation))
            if self.isContinuousVoiceActivationCurrent(generation) {
                self.automaticRearmTask = nil
            }
        }
    }

}

private struct HostLifecycleTransition {
    let generation: Int
    let state: ConversationHostLifecycleState
    let inputCancellation: InputOperation?
    let replyCleanup: Task<Void, Never>?
}

private enum ConversationControllerError: LocalizedError, ReviewedConversationPipelineError {
    case invalidReply(String)

    var errorDescription: String? {
        switch self {
        case .invalidReply(let message): message
        }
    }

    var reviewedMessage: String {
        switch self {
        case .invalidReply(let message): message
        }
    }
}

private enum VoiceInputStartTrigger {
    case explicit
    case automatic(Int)
}
