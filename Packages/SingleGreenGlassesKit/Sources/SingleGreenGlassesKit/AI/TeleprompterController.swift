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

    private let dependencies: TeleprompterDependencies
    private let aligner: TeleprompterScriptAligner
    private var revision = 0
    private var generation = 0
    private var session: (any SpeechRecognitionSession)?
    private var eventTask: Task<Void, Never>?
    private var cleanupTaskGeneration = 0
    private var cleanupTasks: [Int: Task<Void, Never>] = [:]
    private var preparationTaskGeneration = 0
    private var preparationTasks: [Int: Task<Void, Never>] = [:]
    private var activePreparationTaskID: Int?
    private var tentativeSentenceIndex: Int?
    private var tentativeObservationCount = 0
    private var isShutdown = false

    private static let consentDeniedError = "未同意云端语音识别，已保持手动模式。"
    private static let consentRevokedError = "云端语音识别授权已关闭，已保持手动模式。"

    var pendingHostLifecycleCleanupCount: Int { cleanupTasks.count }
    var pendingPreparationTaskCount: Int { preparationTasks.count }

    public init(
        script: TeleprompterScript? = nil,
        dependencies: TeleprompterDependencies,
        aligner: TeleprompterScriptAligner = .init()
    ) {
        self.dependencies = dependencies
        self.aligner = aligner
        let initialState = TeleprompterState(script: script)
        self.state = initialState
        self.snapshot = Self.makeSnapshot(state: initialState, revision: 0)
    }

    public func loadScript(_ source: String) async {
        guard !isShutdown else { return }
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        do {
            state = TeleprompterState(script: try TeleprompterScript(source))
        } catch {
            state = TeleprompterState(userSafeError: "稿件为空，请先粘贴文字。")
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
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        state = TeleprompterState(script: state.script)
        publish()
    }

    public func shutdown() async {
        guard !isShutdown else { return }
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
    }

    private func correctAnchor(to index: Int) async {
        guard !isShutdown, let script = state.script else { return }
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
        let operation = await invalidateAllWork(cancelSession: true)
        guard isCurrent(operation) else { return }
        setPhase(.paused, error: nil)
        await startFollowing()
    }

    private func restartCompletedScript() async {
        guard let script = state.script else { return }
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
            let match = aligner.bestMatch(
                transcript: text,
                script: script,
                anchor: state.sentenceIndex
            )
            let progress = match?.sentenceIndex == state.sentenceIndex || match == nil
                ? updateReadingProgress(text, script: script)
                : nil
            guard let match else {
                clearTentativeAlignment()
                return false
            }
            let completionFraction = max(
                progress?.fraction ?? currentSentenceReadingFraction(script: script),
                match.confidence >= 0.95 ? 1 : 0
            )
            if match.sentenceIndex == state.sentenceIndex,
               completionFraction < 0.88 {
                clearTentativeAlignment()
                return false
            }
            if tentativeSentenceIndex == match.sentenceIndex {
                tentativeObservationCount += 1
            } else {
                tentativeSentenceIndex = match.sentenceIndex
                tentativeObservationCount = 1
            }
            guard tentativeObservationCount >= 2 else { return false }
            return await acceptAlignment(match.sentenceIndex, script: script)
        case .utterance(let text):
            guard let script = state.script else { return false }
            let match = aligner.bestMatch(
                transcript: text,
                script: script,
                anchor: state.sentenceIndex
            )
            let progress = match?.sentenceIndex == state.sentenceIndex || match == nil
                ? updateReadingProgress(text, script: script)
                : nil
            if let match, match.sentenceIndex > state.sentenceIndex {
                return await acceptAlignment(match.sentenceIndex, script: script)
            }
            let completionFraction = max(
                progress?.fraction ?? currentSentenceReadingFraction(script: script),
                (match?.confidence ?? 0) >= 0.95 ? 1 : 0
            )
            guard completionFraction >= 0.82 else {
                clearTentativeAlignment()
                return false
            }
            return await acceptAlignment(state.sentenceIndex, script: script)
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

    private func acceptAlignment(
        _ matchedSentenceIndex: Int,
        script: TeleprompterScript
    ) async -> Bool {
        clearTentativeAlignment()
        let nextSentenceIndex = matchedSentenceIndex + 1
        if nextSentenceIndex >= script.sentences.count {
            generation += 1
            let completedSession = session
            session = nil
            eventTask = nil
            state = TeleprompterState(
                script: script,
                sentenceIndex: script.sentences.count - 1,
                phase: .completed
            )
            publish()
            await completedSession?.cancel()
            return true
        }
        state = TeleprompterState(
            script: script,
            sentenceIndex: nextSentenceIndex,
            readingUTF16Offset: 0,
            phase: .listening
        )
        publish()
        return false
    }

    private func clearTentativeAlignment() {
        tentativeSentenceIndex = nil
        tentativeObservationCount = 0
    }

    @discardableResult
    private func updateReadingProgress(
        _ transcript: String,
        script: TeleprompterScript
    ) -> TeleprompterSentenceProgressMatch? {
        let sentence = script.sentences[state.sentenceIndex]
        guard let match = aligner.readingProgress(
            transcript: transcript,
            sentence: sentence,
            minimumUTF16Offset: state.readingUTF16Offset
        ) else { return nil }
        guard match.utf16Offset > state.readingUTF16Offset else { return match }
        state = TeleprompterState(
            script: script,
            sentenceIndex: state.sentenceIndex,
            readingUTF16Offset: match.utf16Offset,
            phase: state.phase,
            userSafeError: state.userSafeError
        )
        publish()
        return match
    }

    private func currentSentenceReadingFraction(script: TeleprompterScript) -> Double {
        let sentenceLength = max(
            (script.sentences[state.sentenceIndex] as NSString).length,
            1
        )
        return Double(state.readingUTF16Offset) / Double(sentenceLength)
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
