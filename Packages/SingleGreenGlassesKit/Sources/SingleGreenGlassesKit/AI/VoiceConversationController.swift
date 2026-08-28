import Foundation
import VoiceChatDomain

public enum ConversationHostLifecycleState: Equatable, Sendable {
    case active
    case background
}

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
    private var phaseStartedAt: [ConversationTelemetryPhase: UInt64] = [:]
    private var operationGeneration = 0
    private var lifecycleGeneration = 0
    private var isHostActive = true
    private var lifecycleTask: Task<Void, Never>?
    private var continuousVoiceActivationGeneration = 0
    private var activeContinuousVoiceActivation: Int?
    private var automaticRearmTask: Task<Void, Never>?

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
        self.displayScheduler = ConversationDisplayScheduler(
            policy: dependencies.streamingTextPolicy,
            sleep: dependencies.sleep,
            reduceMotion: dependencies.reduceMotion
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
        let transition = beginHostLifecycleTransition(.background)
        await applyHostLifecycle(transition)
    }

    /// Captures scene changes synchronously, then serializes their asynchronous
    /// cleanup through a generation check. A delayed background task therefore
    /// cannot cancel work created after a newer foreground transition.
    public func updateHostLifecycle(_ state: ConversationHostLifecycleState) {
        let transition = beginHostLifecycleTransition(state)
        lifecycleTask = Task { [weak self] in
            await self?.applyHostLifecycle(transition)
        }
    }

    public func waitForPendingHostLifecycleTransition() async {
        await lifecycleTask?.value
    }

    private func applyHostLifecycle(_ transition: HostLifecycleTransition) async {
        guard transition.state == .background else {
            guard transition.generation == lifecycleGeneration else { return }
            record(.lifecycle, outcome: .succeeded)
            return
        }
        if let cancellation = transition.inputCancellation {
            await inputCoordinator.completeCancellation(cancellation)
        }
        await transition.replyCleanup?.value
    }

    /// Foregrounding is intentionally passive. Input and network work resume only
    /// after a new explicit user action.
    public func resumeFromForeground() {
        updateHostLifecycle(.active)
    }

    public func resetConversation() async {
        disableContinuousVoiceActivation()
        let controllerOperation = beginConversationOperation()
        terminateActiveWork(outcome: .cancelled)
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
        disableContinuousVoiceActivation()
        _ = beginConversationOperation()
        terminateActiveWork(outcome: .cancelled)
        _ = await inputCoordinator.cancel()
        await invalidatePendingReply()
        await replyPipeline.clearContext()
    }

    private func startListening(trigger: VoiceInputStartTrigger) async {
        switch trigger {
        case .explicit:
            disableContinuousVoiceActivation()
        case .automatic(let generation):
            guard isContinuousVoiceActivationCurrent(generation), state == .completed else { return }
        }
        guard state.allowsPrimaryAction, state != .listening else { return }
        let controllerOperation = beginConversationOperation()
        terminateActiveWork(outcome: .cancelled)
        await invalidatePendingReply()
        guard isCurrent(controllerOperation) else { return }
        let operation = await inputCoordinator.beginStart()
        guard isCurrent(controllerOperation), inputCoordinator.isCurrent(operation) else { return }

        beginTelemetry(.input)
        let inputMode = dependencies.inputMode()
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
                recordIfActive(.input, outcome: .cancelled)
                return
            }
            continuousGeneration = generation
        }
        guard inputMode != .voiceActivated
                || dependencies.voiceActivatedInputAvailable() else {
            disableContinuousVoiceActivation()
            await inputCoordinator.fail(
                dependencies.presentationCopy.voiceActivatedUnavailable,
                failureCode: .configurationMissing
            )
            return
        }
        let preparedInput: PreparedSpeechInputSession
        beginTelemetry(.preparation)
        do {
            preparedInput = try await dependencies.prepareSpeechInput(inputMode)
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
                recordIfActive(.preparation, outcome: .failed, failure: .protocolFailure)
                await inputCoordinator.fail(
                    dependencies.presentationCopy.speechRecognitionUnavailable,
                    failureCode: .protocolFailure
                )
                return
            }
            recordIfActive(.preparation, outcome: .succeeded)
        } catch {
            guard isInputStartCurrent(
                controllerOperation,
                inputOperation: operation,
                continuousGeneration: continuousGeneration
            ) else { return }
            let failure = error as? ConversationPreparationFailure
            recordIfActive(
                .preparation,
                outcome: .failed,
                failure: failure?.failureCode ?? .preparationUnavailable
            )
            await inputCoordinator.fail(
                failure?.userSafeMessage ?? dependencies.presentationCopy.speechRecognitionUnavailable,
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
                await dependencies.requestMicrophonePermission()
            },
            copy: dependencies.presentationCopy
        )
    }

    private func stopRecognition() async {
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
            lastError = dependencies.presentationCopy.noSpeech
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
        beginTelemetry(.reply)
        let preparedAgent: PreparedConversationAgent
        beginTelemetry(.preparation)
        do {
            preparedAgent = try await dependencies.prepareAgent()
            guard isCurrent(controllerOperation) else {
                await preparedAgent.discard()
                return
            }
            recordIfActive(.preparation, outcome: .succeeded)
        } catch {
            guard isCurrent(controllerOperation) else { return }
            let failure = error as? ConversationPreparationFailure
            recordIfActive(
                .preparation,
                outcome: .failed,
                failure: failure?.failureCode ?? .preparationUnavailable
            )
            failReplyConfiguration(
                failure?.userSafeMessage ?? dependencies.presentationCopy.replyPreparationUnavailable,
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
            incompleteStreamMessage: dependencies.presentationCopy.incompleteReplyStream,
            unexpectedFailureMessage: dependencies.presentationCopy.unexpectedReplyFailure
        )
        guard isCurrent(controllerOperation), replyPipeline.isCurrent(operation) else { return }
        displayScheduler.begin(operation)
        beginTelemetry(.display)
        refreshSnapshot()
    }

    private func failReplyConfiguration(
        _ message: String,
        failureCode: ConversationFailureCode
    ) {
        disableContinuousVoiceActivation()
        lastError = message
        conversation.inputState = .idle
        recordIfActive(.reply, outcome: .failed, failure: failureCode)
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
            throw ConversationControllerError.invalidReply(dependencies.presentationCopy.emptyReply)
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
                dependencies.presentationCopy.inconsistentReplyStream
            )
        }
    }

    private func invalidatePendingReply() async {
        _ = conversation.cancelActiveReply()
        displayScheduler.reset()
        await replyPipeline.invalidate()
        recordIfActive(.display, outcome: .cancelled)
        recordIfActive(.reply, outcome: .cancelled)
    }

    private func handleVisibleTextChanged(_ text: String, operation: ReplyOperation) {
        guard replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id else { return }
        refreshSnapshot()
    }

    private func acceptAcknowledgedReply(operation: ReplyOperation) -> Bool {
        guard replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id,
              conversation.completeReply(id: operation.id) else { return false }
        lastError = nil
        recordIfActive(.display, outcome: .succeeded)
        recordIfActive(.reply, outcome: .succeeded)
        refreshSnapshot()
        scheduleAutomaticRearmIfNeeded()
        return true
    }

    private func failReplyContextAcknowledgement(operation: ReplyOperation) {
        guard replyPipeline.isCurrent(operation),
              conversation.activeReplyID == operation.id,
              displayScheduler.settleFailure(
                discardPartial: false,
                for: operation
              )?.preservesPartial == true else { return }
        disableContinuousVoiceActivation()
        let message = dependencies.presentationCopy.contextCommitFailed
        _ = conversation.failReply(
            id: operation.id,
            message: message,
            preservingPartial: true
        )
        lastError = message
        recordIfActive(.display, outcome: .succeeded)
        recordIfActive(.reply, outcome: .failed, failure: .contextCommitFailed)
        refreshSnapshot()
    }

    private func handleReplyPipelineEvent(_ event: ReplyPipelineEvent) throws {
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
            ? dependencies.presentationCopy.interruptedReplyPrefix
            : dependencies.presentationCopy.failedReplyPrefix
        let message = "\(prefix)\(failure.message)"
        _ = conversation.failReply(
            id: operation.id,
            message: message,
            preservingPartial: hasPartialReply
        )
        lastError = message
        recordIfActive(.display, outcome: .failed, failure: .interrupted)
        recordIfActive(.reply, outcome: .failed, failure: failure.failureCode)
        refreshSnapshot()
    }

    private func handleInputCoordinatorEvent(_ event: InputCoordinatorEvent) async {
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
            recordIfActive(.input, outcome: .succeeded)
            refreshSnapshot()
        case .finished(let operation):
            guard inputCoordinator.isCurrent(operation) else { return }
            recordIfActive(.input, outcome: .succeeded)
            await finishASRAndRequestReply(operation: operation)
        case .failed(let operation, let message, let failure):
            guard inputCoordinator.isCurrent(operation) else { return }
            disableContinuousVoiceActivation()
            audioLevel = 0
            liveText = ""
            lastError = message
            conversation.inputState = .failed(message)
            recordIfActive(.input, outcome: .failed, failure: failure)
            refreshSnapshot()
        }
    }

    private func beginTelemetry(_ phase: ConversationTelemetryPhase) {
        recordIfActive(phase, outcome: .cancelled)
        phaseStartedAt[phase] = dependencies.monotonicNow()
        dependencies.telemetry.record(.init(
            phase: phase,
            outcome: .started,
            elapsedMilliseconds: 0
        ))
    }

    private func record(
        _ phase: ConversationTelemetryPhase,
        outcome: ConversationTelemetryOutcome,
        failure: ConversationFailureCode? = nil
    ) {
        let now = dependencies.monotonicNow()
        let start = phaseStartedAt.removeValue(forKey: phase) ?? now
        let elapsed = now >= start ? (now - start) / 1_000_000 : 0
        dependencies.telemetry.record(.init(
            phase: phase,
            outcome: outcome,
            elapsedMilliseconds: elapsed,
            failureCode: failure
        ))
    }

    private func recordIfActive(
        _ phase: ConversationTelemetryPhase,
        outcome: ConversationTelemetryOutcome,
        failure: ConversationFailureCode? = nil
    ) {
        guard phaseStartedAt[phase] != nil else { return }
        record(phase, outcome: outcome, failure: failure)
    }

    private func refreshSnapshot() {
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

    private func beginConversationOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    private func isCurrent(
        _ operation: Int,
        requiresActiveHost: Bool = true
    ) -> Bool {
        operation == operationGeneration && (!requiresActiveHost || isHostActive)
    }

    private func beginHostLifecycleTransition(
        _ state: ConversationHostLifecycleState
    ) -> HostLifecycleTransition {
        lifecycleGeneration += 1
        isHostActive = state == .active
        _ = beginConversationOperation()
        let inputCancellation = state == .background
            ? inputCoordinator.reserveCancellation()
            : nil
        let replyCleanup = state == .background
            ? replyPipeline.beginInvalidation()
            : nil
        if state == .background {
            disableContinuousVoiceActivation()
            terminateActiveWork(outcome: .suspended)
            _ = conversation.abortUncommittedTurn()
            displayScheduler.reset()
            conversation.inputState = .idle
            liveText = ""
            audioLevel = 0
            lastError = nil
            record(.lifecycle, outcome: .suspended)
            refreshSnapshot()
        }
        return HostLifecycleTransition(
            generation: lifecycleGeneration,
            state: state,
            inputCancellation: inputCancellation,
            replyCleanup: replyCleanup
        )
    }

    private func terminateActiveWork(outcome: ConversationTelemetryOutcome) {
        recordIfActive(.preparation, outcome: outcome)
        recordIfActive(.input, outcome: outcome)
        recordIfActive(.display, outcome: outcome)
        recordIfActive(.reply, outcome: outcome)
    }

    private func beginContinuousVoiceActivation() -> Int {
        continuousVoiceActivationGeneration += 1
        activeContinuousVoiceActivation = continuousVoiceActivationGeneration
        return continuousVoiceActivationGeneration
    }

    private func disableContinuousVoiceActivation() {
        continuousVoiceActivationGeneration += 1
        activeContinuousVoiceActivation = nil
        automaticRearmTask?.cancel()
        automaticRearmTask = nil
    }

    private func isContinuousVoiceActivationCurrent(_ generation: Int) -> Bool {
        activeContinuousVoiceActivation == generation
            && continuousVoiceActivationGeneration == generation
            && isHostActive
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
        guard let generation = activeContinuousVoiceActivation,
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
