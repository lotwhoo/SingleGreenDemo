import Foundation

public struct TeleprompterDependencies {
    public let prepareSpeechSession: () async throws -> any SpeechRecognitionSession
    public let requestMicrophonePermission: () async -> Bool
    public let cloudSpeechRecognitionAllowed: () -> Bool

    public init(
        prepareSpeechSession: @escaping () async throws -> any SpeechRecognitionSession,
        requestMicrophonePermission: @escaping () async -> Bool
    ) {
        self.init(
            prepareSpeechSession: prepareSpeechSession,
            requestMicrophonePermission: requestMicrophonePermission,
            cloudSpeechRecognitionAllowed: { false }
        )
    }

    public init(
        prepareSpeechSession: @escaping () async throws -> any SpeechRecognitionSession,
        requestMicrophonePermission: @escaping () async -> Bool,
        cloudSpeechRecognitionAllowed: @escaping () -> Bool
    ) {
        self.prepareSpeechSession = prepareSpeechSession
        self.requestMicrophonePermission = requestMicrophonePermission
        self.cloudSpeechRecognitionAllowed = cloudSpeechRecognitionAllowed
    }
}

@MainActor
public final class TeleprompterController: ObservableObject {
    @Published public private(set) var state: TeleprompterState
    @Published public private(set) var snapshot: ExperienceSnapshot
    @Published public private(set) var canUndoAutomaticJump = false
    @Published public private(set) var checkpointRestoreResult: TeleprompterCheckpointRestoreResult

    private let dependencies: TeleprompterDependencies
    private let positionEngine: ReadingPositionEngine
    private let checkpointStore: any TeleprompterCheckpointStore
    private var revision = 0
    private var generation = 0
    private var session: (any SpeechRecognitionSession)?
    private var eventTask: Task<Void, Never>?
    private var cleanupTaskGeneration = 0
    private var cleanupTasks: [Int: Task<Void, Never>] = [:]
    private var preparationTaskGeneration = 0
    private var preparationTasks: [Int: Task<Void, Never>] = [:]
    private var activePreparationTaskID: Int?
    private var positionStability = ReadingPositionStability()
    private var positionUndo = ReadingPositionUndoState()
    private var alignmentGeneration: UInt64 = 0
    private var isShutdown = false

    private static let consentDeniedError = "未同意云端语音识别，已保持手动模式。"
    private static let consentRevokedError = "云端语音识别授权已关闭，已保持手动模式。"

    var pendingHostLifecycleCleanupCount: Int { cleanupTasks.count }
    var pendingPreparationTaskCount: Int { preparationTasks.count }

    public init(
        script: TeleprompterScript? = nil,
        dependencies: TeleprompterDependencies,
        aligner: TeleprompterScriptAligner = .init(),
        checkpointStore: any TeleprompterCheckpointStore = NoopTeleprompterCheckpointStore()
    ) {
        self.dependencies = dependencies
        self.positionEngine = ReadingPositionEngine(aligner: aligner)
        self.checkpointStore = checkpointStore
        let restoration = Self.restoredState(script: script, checkpointStore: checkpointStore)
        let initialState = restoration.state
        self.state = initialState
        self.snapshot = Self.makeSnapshot(state: initialState, revision: 0)
        self.checkpointRestoreResult = restoration.result
    }

    public func loadScript(
        _ source: String,
        identity: TeleprompterScriptIdentity? = nil
    ) async {
        guard !isShutdown else { return }
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        do {
            let script = try identity.map {
                try TeleprompterScript(source, identity: $0)
            } ?? TeleprompterScript(source)
            let restoration = Self.restoredState(
                script: script,
                checkpointStore: checkpointStore
            )
            state = restoration.state
            checkpointRestoreResult = restoration.result
        } catch {
            state = TeleprompterState(userSafeError: "稿件为空，请先粘贴文字。")
            checkpointRestoreResult = .noCheckpoint
        }
        publish()
    }

    public func toggleFollowing() async {
        guard !isShutdown, state.script != nil else {
            if !isShutdown { publish(error: "请先在手机端载入稿件。") }
            return
        }
        if state.phase == .listening || state.phase == .preparing {
            await pause()
        } else if state.phase == .completed {
            await restartCompletedScript()
        } else {
            await startFollowing()
        }
    }

    public func movePrevious() async {
        await correctAnchor(to: max(0, state.sentenceIndex - 1))
    }

    public func moveNext() async {
        guard let script = state.script else { return }
        await correctAnchor(to: min(script.sentences.count - 1, state.sentenceIndex + 1))
    }

    /// Consumes the latest automatic jump exactly once. If recognition was
    /// active, the old session is cancelled and a fresh session starts from the
    /// restored anchor; cancelled callbacks can never mutate the new run.
    public func undoLastAutomaticJump() async {
        guard !isShutdown, let script = state.script else {
            invalidateAutomaticJumpUndo()
            return
        }
        let currentAnchor = readingAnchor
        guard let source = positionUndo.consume(
            scriptVersion: script.version,
            alignmentGeneration: alignmentGeneration,
            currentAnchor: currentAnchor
        ) else {
            refreshUndoAvailability()
            return
        }

        canUndoAutomaticJump = false
        alignmentGeneration &+= 1
        let wasFollowing = state.phase == .listening || state.phase == .preparing
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(
            script: script,
            sentenceIndex: source.sentenceIndex,
            readingUTF16Offset: source.utf16Offset,
            phase: wasFollowing ? .paused : state.phase,
            userSafeError: nil
        )
        publish()
        if wasFollowing { await startFollowing() }
    }

    /// While listening this restarts recognition at the current sentence. In a
    /// non-listening state it toggles manual fallback; a second press retries ASR.
    public func reanchorOrToggleManualFallback() async {
        guard !isShutdown, state.script != nil else { return }
        switch state.phase {
        case .listening, .preparing:
            await restartFollowingAtCurrentAnchor()
        case .manualFallback:
            await startFollowing()
        case .ready, .paused, .completed:
            let operation = await invalidateAllWork(cancelSession: true)
            guard isCurrent(operation) else { return }
            setPhase(.manualFallback, error: nil)
        }
    }

    public func updateCloudSpeechRecognitionConsent(_ isAllowed: Bool) async {
        guard !isShutdown else { return }
        if isAllowed {
            let isStaleConsentError = state.userSafeError == Self.consentDeniedError
                || state.userSafeError == Self.consentRevokedError
            guard state.phase == .manualFallback, isStaleConsentError else { return }
            setPhase(.manualFallback, error: nil)
            return
        }
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        let phase: TeleprompterPhase = state.script == nil ? .ready : .manualFallback
        setPhase(phase, error: Self.consentRevokedError)
    }

    public func updateHostLifecycle(_ lifecycle: ExperienceHostLifecycleState) {
        guard !isShutdown else { return }
        guard lifecycle == .background else { return }
        generation += 1
        let oldPreparationTasks = Array(preparationTasks.values)
        activePreparationTaskID = nil
        oldPreparationTasks.forEach { $0.cancel() }
        let oldSession = session
        let oldEventTask = eventTask
        session = nil
        oldEventTask?.cancel()
        eventTask = nil
        setPhase(state.script == nil ? .ready : .paused, error: nil)
        persistCheckpointIfPossible()
        cleanupTaskGeneration += 1
        let cleanupID = cleanupTaskGeneration
        let cleanup = Task { [weak self] in
            await oldSession?.cancel()
            await oldEventTask?.value
            for task in oldPreparationTasks { await task.value }
            self?.hostLifecycleCleanupDidFinish(cleanupID)
        }
        cleanupTasks[cleanupID] = cleanup
    }

    public func waitForPendingHostLifecycleTransition() async {
        let pendingCleanups = Array(cleanupTasks.values)
        for cleanup in pendingCleanups { await cleanup.value }
    }

    public func reset() async {
        guard !isShutdown else { return }
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(script: state.script)
        publish()
    }

    /// Explicitly ends the current reading run at the authored end position.
    /// Host gestures may adopt this boundary without coupling persistence to UI.
    public func complete() async {
        guard !isShutdown, let script = state.script,
              let lastSentenceIndex = script.sentences.indices.last else { return }
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(
            script: script,
            sentenceIndex: lastSentenceIndex,
            readingUTF16Offset: (script.sentences[lastSentenceIndex] as NSString).length,
            phase: .completed
        )
        publish()
        persistCheckpointIfPossible()
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        persistCheckpointIfPossible()
        beginIncompatibleAlignmentContext()
        isShutdown = true
        generation += 1
        let currentPreparationTasks = Array(preparationTasks.values)
        activePreparationTaskID = nil
        currentPreparationTasks.forEach { $0.cancel() }
        let currentSession = session
        let currentEventTask = eventTask
        session = nil
        eventTask = nil
        currentEventTask?.cancel()
        let currentCleanup = Task {
            await currentSession?.cancel()
            await currentEventTask?.value
            for task in currentPreparationTasks { await task.value }
        }
        let pendingCleanups = Array(cleanupTasks.values) + [currentCleanup]
        for cleanup in pendingCleanups { await cleanup.value }
        cleanupTasks.removeAll()
        preparationTasks.removeAll()
    }

    /// Deletes the script and every persisted artifact behind one abstract,
    /// atomic store operation. Runtime state is cleared only after persistence
    /// confirms deletion; stale recognition events have already been isolated.
    @discardableResult
    public func deleteScript() async -> TeleprompterScriptDeletionResult {
        guard !isShutdown, let script = state.script else { return .alreadyDeleted }
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return .failed }

        let result = checkpointStore.deleteScriptArtifacts(for: script.identity)
        switch result {
        case .deleted, .alreadyDeleted:
            state = TeleprompterState()
            checkpointRestoreResult = .noCheckpoint
            publish()
        case .rejectedIdentity, .failed:
            state = TeleprompterState(
                script: script,
                sentenceIndex: state.sentenceIndex,
                readingUTF16Offset: state.readingUTF16Offset,
                phase: .paused,
                userSafeError: "稿件删除失败，请稍后重试。"
            )
            publish()
        }
        return result
    }

    private func startFollowing() async {
        guard !isShutdown, state.script != nil else { return }
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        setPhase(.preparing, error: nil)
        let task = schedulePreparation(generation: operation, yieldsBeforeStarting: false)
        await task.value
    }

    private func runPreparation(generation operation: Int) async {
        guard isCurrent(operation), !Task.isCancelled else { return }
        guard dependencies.cloudSpeechRecognitionAllowed() else {
            guard isCurrent(operation) else { return }
            setPhase(.manualFallback, error: Self.consentDeniedError)
            return
        }

        guard await dependencies.requestMicrophonePermission() else {
            guard isCurrent(operation) else { return }
            setPhase(.manualFallback, error: "未获得麦克风权限，已切换为手动模式。")
            return
        }
        guard isCurrent(operation), !Task.isCancelled else { return }

        let preparedSession: any SpeechRecognitionSession
        do {
            preparedSession = try await dependencies.prepareSpeechSession()
        } catch {
            guard isCurrent(operation) else { return }
            setPhase(.manualFallback, error: "语音识别暂不可用，已切换为手动模式。")
            return
        }
        guard isCurrent(operation), !Task.isCancelled else {
            await preparedSession.cancel()
            return
        }

        session = preparedSession
        let events = preparedSession.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                if await self?.consume(event, generation: operation) == true { return }
            }
        }
        do {
            try await preparedSession.start()
            guard isCurrent(operation), !Task.isCancelled, session === preparedSession else {
                await preparedSession.cancel()
                return
            }
            setPhase(.listening, error: nil)
        } catch {
            guard isCurrent(operation) else { return }
            await invalidateSession(cancel: true)
            setPhase(.manualFallback, error: "语音识别暂不可用，已切换为手动模式。")
        }
    }

    private func pause() async {
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        setPhase(state.script == nil ? .ready : .paused, error: nil)
        persistCheckpointIfPossible()
    }

    private func correctAnchor(to index: Int) async {
        guard !isShutdown, let script = state.script else { return }
        beginIncompatibleAlignmentContext()
        let wasFollowing = state.phase == .listening || state.phase == .preparing
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(
            script: script,
            sentenceIndex: index,
            phase: wasFollowing || state.phase == .completed ? .paused : state.phase,
            userSafeError: nil
        )
        publish()
        if wasFollowing { await startFollowing() }
    }

    private func restartFollowingAtCurrentAnchor() async {
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        setPhase(.paused, error: nil)
        await startFollowing()
    }

    private func restartCompletedScript() async {
        guard let script = state.script else { return }
        beginIncompatibleAlignmentContext()
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(script: script, sentenceIndex: 0, phase: .ready)
        publish()
        await startFollowing()
    }

    private func consume(
        _ event: SpeechRecognitionEvent,
        generation operation: Int
    ) async -> Bool {
        guard isCurrent(operation), !isShutdown else { return true }
        switch event {
        case .transcript(let text):
            guard let script = state.script else { return false }
            return await consumeReadingPosition(
                text,
                semantics: .partial,
                script: script
            )
        case .utterance(let text):
            guard let script = state.script else { return false }
            return await consumeReadingPosition(
                text,
                semantics: .final,
                script: script
            )
        case .finished:
            generation += 1
            clearTentativeAlignment()
            session = nil
            eventTask = nil
            setPhase(.preparing, error: nil)
            let rotationGeneration = generation
            _ = schedulePreparation(
                generation: rotationGeneration,
                yieldsBeforeStarting: true
            )
            return true
        case .failed:
            generation += 1
            clearTentativeAlignment()
            session = nil
            eventTask = nil
            setPhase(.manualFallback, error: "语音识别连接中断，已切换为手动模式。")
            return true
        case .level:
            return false
        }
    }

    private func consumeReadingPosition(
        _ transcriptFragment: String,
        semantics: ReadingRecognitionEventSemantics,
        script: TeleprompterScript
    ) async -> Bool {
        let evaluation = positionEngine.evaluate(
            ReadingPositionInput(
                script: script,
                scriptVersion: script.version,
                anchor: ReadingPositionAnchor(
                    sentenceIndex: state.sentenceIndex,
                    utf16Offset: state.readingUTF16Offset
                ),
                transcriptFragment: transcriptFragment,
                eventSemantics: semantics
            ),
            stability: positionStability
        )
        positionStability = evaluation.nextStability

        switch evaluation.decision {
        case .stay:
            return false
        case .advance(let target, _, _):
            invalidateAutomaticJumpUndo()
            return await applyReadingPosition(target, script: script)
        case .jump(let target, _, _, _):
            let source = readingAnchor
            invalidateAutomaticJumpUndo()
            let didFinish = await applyReadingPosition(target, script: script)
            if !didFinish, readingAnchor != source, readingAnchor == target {
                positionUndo.record(
                    scriptVersion: script.version,
                    alignmentGeneration: alignmentGeneration,
                    source: source,
                    target: target
                )
                refreshUndoAvailability()
            }
            return didFinish
        }
    }

    private func applyReadingPosition(
        _ target: ReadingPositionAnchor,
        script: TeleprompterScript
    ) async -> Bool {
        let lastSentenceIndex = script.sentences.count - 1
        let lastSentenceLength = (script.sentences[lastSentenceIndex] as NSString).length
        if target.sentenceIndex == lastSentenceIndex,
           target.utf16Offset >= lastSentenceLength {
            beginIncompatibleAlignmentContext()
            generation += 1
            clearTentativeAlignment()
            let completedSession = self.session
            session = nil
            eventTask = nil
            state = TeleprompterState(
                script: script,
                sentenceIndex: lastSentenceIndex,
                readingUTF16Offset: lastSentenceLength,
                phase: .completed
            )
            publish()
            persistCheckpointIfPossible()
            await completedSession?.cancel()
            return true
        }

        guard target.sentenceIndex != state.sentenceIndex
                || target.utf16Offset > state.readingUTF16Offset else {
            return false
        }
        state = TeleprompterState(
            script: script,
            sentenceIndex: target.sentenceIndex,
            readingUTF16Offset: target.utf16Offset,
            phase: state.phase,
            userSafeError: state.userSafeError
        )
        publish()
        return false
    }

    private func clearTentativeAlignment() {
        positionStability = ReadingPositionStability()
    }

    private var readingAnchor: ReadingPositionAnchor {
        ReadingPositionAnchor(
            sentenceIndex: state.sentenceIndex,
            utf16Offset: state.readingUTF16Offset
        )
    }

    private func beginIncompatibleAlignmentContext() {
        alignmentGeneration &+= 1
        invalidateAutomaticJumpUndo()
    }

    private func invalidateAutomaticJumpUndo() {
        positionUndo.invalidate()
        canUndoAutomaticJump = false
    }

    private func refreshUndoAvailability() {
        guard let script = state.script else {
            canUndoAutomaticJump = false
            return
        }
        canUndoAutomaticJump = positionUndo.isAvailable(
            scriptVersion: script.version,
            alignmentGeneration: alignmentGeneration,
            currentAnchor: readingAnchor
        )
    }

    @discardableResult
    private func persistCheckpointIfPossible() -> TeleprompterCheckpointWriteResult {
        guard let script = state.script,
              let checkpoint = TeleprompterCheckpointResolver.makeCheckpoint(
                script: script,
                anchor: readingAnchor
              ) else {
            return .unchanged
        }
        return checkpointStore.saveCheckpoint(checkpoint)
    }

    private static func restoredState(
        script: TeleprompterScript?,
        checkpointStore: any TeleprompterCheckpointStore
    ) -> (state: TeleprompterState, result: TeleprompterCheckpointRestoreResult) {
        guard let script else {
            return (TeleprompterState(), .noCheckpoint)
        }
        let result = TeleprompterCheckpointResolver.resolve(
            checkpointStore.loadCheckpoint(for: script),
            for: script
        )
        switch result {
        case .restored(let anchor):
            return (
                TeleprompterState(
                    script: script,
                    sentenceIndex: anchor.sentenceIndex,
                    readingUTF16Offset: anchor.utf16Offset,
                    phase: .ready
                ),
                result
            )
        case .noCheckpoint, .rejected:
            return (TeleprompterState(script: script), result)
        }
    }

    private func hostLifecycleCleanupDidFinish(_ cleanupID: Int) {
        cleanupTasks[cleanupID] = nil
    }

    private func schedulePreparation(
        generation operation: Int,
        yieldsBeforeStarting: Bool
    ) -> Task<Void, Never> {
        preparationTaskGeneration += 1
        let taskID = preparationTaskGeneration
        let task = Task { [weak self] in
            if yieldsBeforeStarting { await Task.yield() }
            guard let self,
                  self.isCurrent(operation),
                  self.state.phase == .preparing,
                  !Task.isCancelled else {
                self?.preparationDidFinish(taskID)
                return
            }
            await self.runPreparation(generation: operation)
            self.preparationDidFinish(taskID)
        }
        preparationTasks[taskID] = task
        activePreparationTaskID = taskID
        return task
    }

    private func preparationDidFinish(_ taskID: Int) {
        preparationTasks[taskID] = nil
        if activePreparationTaskID == taskID {
            activePreparationTaskID = nil
        }
    }

    private func invalidateAllWork(cancelSession: Bool) async -> Int {
        generation += 1
        let operation = generation
        let oldPreparationTasks = Array(preparationTasks.values)
        activePreparationTaskID = nil
        oldPreparationTasks.forEach { $0.cancel() }
        await invalidateSession(cancel: cancelSession)
        for task in oldPreparationTasks { await task.value }
        return operation
    }

    private func invalidateSession(cancel: Bool) async {
        let oldTask = eventTask
        let oldSession = session
        clearTentativeAlignment()
        eventTask = nil
        session = nil
        oldTask?.cancel()
        if cancel { await oldSession?.cancel() }
        await oldTask?.value
    }

    private func isCurrent(_ operation: Int) -> Bool {
        !isShutdown && generation == operation
    }

    private func setPhase(_ phase: TeleprompterPhase, error: String?) {
        state = TeleprompterState(
            script: state.script,
            sentenceIndex: state.sentenceIndex,
            readingUTF16Offset: state.readingUTF16Offset,
            phase: phase,
            userSafeError: error
        )
        publish()
    }

    private func publish(error: String? = nil) {
        if let error {
            state = TeleprompterState(
                script: state.script,
                sentenceIndex: state.sentenceIndex,
                readingUTF16Offset: state.readingUTF16Offset,
                phase: state.phase,
                userSafeError: error
            )
        }
        revision += 1
        snapshot = Self.makeSnapshot(state: state, revision: revision)
    }

    private static func makeSnapshot(
        state: TeleprompterState,
        revision: Int
    ) -> ExperienceSnapshot {
        let phaseCopy: (String, String, String) = switch state.phase {
        case .ready: ("提词器就绪", "载入稿件后可开始", "play.fill")
        case .preparing: ("正在准备", "连接语音识别", "hourglass")
        case .listening: ("语音跟随中", "朗读会自动推进", "pause.fill")
        case .paused: ("已暂停", "当前位置已保留", "play.fill")
        case .manualFallback: ("手动模式", "可用左右键调整", "waveform.badge.plus")
        case .completed: ("提词已完成", "按上键可从头开始", "checkmark.circle.fill")
        }
        let primaryActionTitle: String = switch state.phase {
        case .listening, .preparing: "暂停跟随"
        case .completed: "重新开始"
        case .ready, .paused, .manualFallback: "开始跟随"
        }
        return ExperienceSnapshot(
            scene: TeleprompterHUDMapper.scene(for: state, revision: revision),
            primaryActionTitle: primaryActionTitle,
            eventDescription: "teleprompter_\(revision)",
            controlState: ExperienceControlState(
                statusTitle: phaseCopy.0,
                statusDetail: phaseCopy.1,
                errorMessage: state.userSafeError,
                primaryActionSystemImage: phaseCopy.2,
                allowsPrimaryAction: state.script != nil
            )
        )
    }
}
