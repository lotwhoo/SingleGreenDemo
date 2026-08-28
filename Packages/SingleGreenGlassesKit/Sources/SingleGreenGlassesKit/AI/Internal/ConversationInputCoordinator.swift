import Foundation

struct InputOperation: Equatable, Sendable {
    let generation: Int
}

enum InputCoordinatorEvent: Sendable {
    case preparing(InputOperation)
    case armed(InputOperation)
    case recording(InputOperation)
    case finalizing(InputOperation)
    case transcript(InputOperation, String)
    case level(InputOperation, Float)
    case noSpeech(InputOperation)
    case finished(InputOperation)
    case failed(InputOperation, String, ConversationFailureCode)
}

@MainActor
final class ConversationInputCoordinator {
    private var speechSession: (any SpeechRecognitionSession)?
    private var voiceActivatedSession: (any VoiceActivatedSpeechRecognitionSession)?
    private var eventsTask: Task<Void, Never>?
    private var generation = 0
    private var didHandleFinal = false
    private var speechRecognitionUnavailableMessage = ""

    var onEvent: @MainActor (InputCoordinatorEvent) async -> Void = { _ in }

    init() {}

    deinit {
        eventsTask?.cancel()
        let activeSpeechSession = speechSession
        let activeVoiceActivatedSession = voiceActivatedSession
        Task {
            await activeSpeechSession?.cancel()
            await activeVoiceActivatedSession?.cancel()
        }
    }

    func beginStart() async -> InputOperation {
        let operation = beginOperation()
        await cancelResources()
        return operation
    }

    func start(
        operation: InputOperation,
        preparedInput: PreparedSpeechInputSession,
        requestPermission: () async -> Bool,
        copy: ConversationPresentationCopy
    ) async {
        guard isCurrent(operation) else {
            await preparedInput.cancel()
            return
        }
        didHandleFinal = false
        speechRecognitionUnavailableMessage = copy.speechRecognitionUnavailable

        switch preparedInput {
        case .pushToTalk(let session): speechSession = session
        case .voiceActivated(let session): voiceActivatedSession = session
        }

        await onEvent(.preparing(operation))
        guard isCurrent(operation) else { return }

        let permissionGranted = await requestPermission()
        guard isCurrent(operation) else { return }
        guard permissionGranted else {
            await fail(
                operation,
                message: copy.microphonePermissionDenied,
                failureCode: .microphonePermissionDenied
            )
            return
        }

        switch preparedInput {
        case .pushToTalk(let newSession):
            observe(newSession, operation: operation)
            do {
                try await newSession.start()
                guard isCurrent(operation), isActive(newSession) else {
                    await newSession.cancel()
                    return
                }
                await onEvent(.recording(operation))
            } catch {
                await handleStartFailure(
                    error,
                    session: newSession,
                    operation: operation,
                    copy: copy
                )
            }
        case .voiceActivated(let newSession):
            observe(newSession, operation: operation)
            do {
                try await newSession.arm()
                guard isCurrent(operation), isActive(newSession) else {
                    await newSession.cancel()
                    return
                }
            } catch {
                await handleStartFailure(
                    error,
                    session: newSession,
                    operation: operation,
                    copy: copy
                )
            }
        }
    }

    func finishCurrent() async {
        let operation = InputOperation(generation: generation)
        if let speechSession {
            await onEvent(.finalizing(operation))
            guard isCurrent(operation), isActive(speechSession) else { return }
            await speechSession.finish()
        } else if let voiceActivatedSession {
            guard isCurrent(operation), isActive(voiceActivatedSession) else { return }
            // The session reports either noSpeech (before onset) or an explicit
            // finalizing(.manual) phase (after onset); do not guess here.
            await voiceActivatedSession.finish()
        }
    }

    @discardableResult
    func cancel() async -> InputOperation {
        let operation = reserveCancellation()
        await completeCancellation(operation)
        return operation
    }

    func reserveCancellation() -> InputOperation {
        beginOperation()
    }

    func completeCancellation(_ operation: InputOperation) async {
        guard isCurrent(operation) else { return }
        await cancelResources()
    }

    func fail(_ message: String, failureCode: ConversationFailureCode) async {
        let operation = beginOperation()
        await cancelResources()
        guard isCurrent(operation) else { return }
        await onEvent(.failed(operation, message, failureCode))
    }

    func isCurrent(_ operation: InputOperation) -> Bool {
        operation.generation == generation
    }

    private func observe(
        _ session: any SpeechRecognitionSession,
        operation: InputOperation
    ) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, from: session, operation: operation)
            }
        }
    }

    private func observe(
        _ session: any VoiceActivatedSpeechRecognitionSession,
        operation: InputOperation
    ) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, from: session, operation: operation)
            }
        }
    }

    private func handle(
        _ event: SpeechRecognitionEvent,
        from session: any SpeechRecognitionSession,
        operation: InputOperation
    ) async {
        guard isCurrent(operation), isActive(session) else { return }
        switch event {
        case .transcript(let text):
            await onEvent(.transcript(operation, text))
        case .utterance:
            break
        case .level(let value):
            await onEvent(.level(operation, value))
        case .finished:
            guard !didHandleFinal else { return }
            didHandleFinal = true
            detachFinishedSession(session)
            await onEvent(.finished(operation))
        case .failed(let failure):
            await fail(
                operation,
                message: failure.userSafeMessage ?? speechRecognitionUnavailableMessage,
                failureCode: failure.code.telemetryCode
            )
        }
    }

    private func handle(
        _ event: VoiceActivatedRecognitionEvent,
        from session: any VoiceActivatedSpeechRecognitionSession,
        operation: InputOperation
    ) async {
        guard isCurrent(operation), isActive(session) else { return }
        switch event {
        case .phase(.armed):
            await onEvent(.armed(operation))
        case .phase(.speechStarted):
            await onEvent(.recording(operation))
        case .phase(.finalizing):
            await onEvent(.finalizing(operation))
        case .transcript(let text):
            await onEvent(.transcript(operation, text))
        case .utterance:
            break
        case .level(let value):
            await onEvent(.level(operation, value))
        case .noSpeech:
            guard !didHandleFinal else { return }
            didHandleFinal = true
            detachFinishedSession(session)
            await onEvent(.noSpeech(operation))
        case .finished:
            guard !didHandleFinal else { return }
            didHandleFinal = true
            detachFinishedSession(session)
            await onEvent(.finished(operation))
        case .failed(let failure):
            await fail(
                operation,
                message: failure.userSafeMessage ?? speechRecognitionUnavailableMessage,
                failureCode: failure.code.telemetryCode
            )
        }
    }

    private func handleStartFailure(
        _ error: Error,
        session: any SpeechRecognitionSession,
        operation: InputOperation,
        copy: ConversationPresentationCopy
    ) async {
        guard isCurrent(operation), isActive(session) else {
            await session.cancel()
            return
        }
        await failStart(error, operation: operation, copy: copy)
    }

    private func handleStartFailure(
        _ error: Error,
        session: any VoiceActivatedSpeechRecognitionSession,
        operation: InputOperation,
        copy: ConversationPresentationCopy
    ) async {
        guard isCurrent(operation), isActive(session) else {
            await session.cancel()
            return
        }
        await failStart(error, operation: operation, copy: copy)
    }

    private func failStart(
        _ error: Error,
        operation: InputOperation,
        copy: ConversationPresentationCopy
    ) async {
        if let failure = error as? SpeechRecognitionFailure {
            await fail(
                operation,
                message: failure.userSafeMessage ?? copy.speechRecognitionUnavailable,
                failureCode: failure.code.telemetryCode
            )
        } else {
            await fail(
                operation,
                message: copy.speechRecognitionUnavailable,
                failureCode: .unknown
            )
        }
    }

    private func fail(
        _ operation: InputOperation,
        message: String,
        failureCode: ConversationFailureCode
    ) async {
        guard isCurrent(operation) else { return }
        await cancelResources()
        guard isCurrent(operation) else { return }
        await onEvent(.failed(operation, message, failureCode))
    }

    private func cancelResources() async {
        eventsTask?.cancel()
        eventsTask = nil
        let activeSpeechSession = speechSession
        let activeVoiceActivatedSession = voiceActivatedSession
        speechSession = nil
        voiceActivatedSession = nil
        didHandleFinal = false
        await activeSpeechSession?.cancel()
        await activeVoiceActivatedSession?.cancel()
    }

    private func detachFinishedSession(_ finishedSession: any SpeechRecognitionSession) {
        guard isActive(finishedSession) else { return }
        eventsTask?.cancel()
        eventsTask = nil
        speechSession = nil
    }

    private func detachFinishedSession(
        _ finishedSession: any VoiceActivatedSpeechRecognitionSession
    ) {
        guard isActive(finishedSession) else { return }
        eventsTask?.cancel()
        eventsTask = nil
        voiceActivatedSession = nil
    }

    private func beginOperation() -> InputOperation {
        generation += 1
        return InputOperation(generation: generation)
    }

    private func isActive(_ candidate: any SpeechRecognitionSession) -> Bool {
        guard let speechSession else { return false }
        return speechSession === candidate
    }

    private func isActive(_ candidate: any VoiceActivatedSpeechRecognitionSession) -> Bool {
        guard let voiceActivatedSession else { return false }
        return voiceActivatedSession === candidate
    }

}

private extension SpeechRecognitionFailure.Code {
    var telemetryCode: ConversationFailureCode {
        switch self {
        case .unauthorized: .unauthorized
        case .networkUnavailable: .networkUnavailable
        case .timeout: .timeout
        case .connectionLost: .connectionLost
        case .audioInterrupted: .audioInterrupted
        case .audioUnavailable: .audioUnavailable
        case .voiceActivityUnavailable: .audioUnavailable
        case .voiceActivityProcessingFailed, .audioCaptureOverrun,
             .uploadBackpressureExceeded: .protocolFailure
        case .protocolFailure: .protocolFailure
        case .unknown: .unknown
        }
    }
}
