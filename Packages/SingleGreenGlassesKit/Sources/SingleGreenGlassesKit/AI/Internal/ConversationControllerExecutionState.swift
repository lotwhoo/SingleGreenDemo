struct ConversationControllerLifecycleTransition: Equatable, Sendable {
    let generation: Int
    let state: ConversationHostLifecycleState
    let conversationOperation: Int
}

/// Pure admission and generation state for the conversation use case.
///
/// The controller continues to own every Task and side effect. Keeping only value state here makes
/// stale-operation and lifecycle decisions independently testable without creating another runtime
/// owner that could race cancellation or cleanup.
struct ConversationControllerExecutionState: Equatable, Sendable {
    private(set) var conversationOperationGeneration = 0
    private(set) var lifecycleGeneration = 0
    private(set) var isHostActive = true
    private(set) var isShutdown = false
    private(set) var continuousVoiceActivationGeneration = 0
    private(set) var activeContinuousVoiceActivation: Int?

    mutating func beginConversationOperation() -> Int {
        conversationOperationGeneration += 1
        return conversationOperationGeneration
    }

    func isConversationOperationCurrent(
        _ operation: Int,
        requiresActiveHost: Bool = true
    ) -> Bool {
        !isShutdown
            && operation == conversationOperationGeneration
            && (!requiresActiveHost || isHostActive)
    }

    mutating func beginHostLifecycleTransition(
        _ state: ConversationHostLifecycleState
    ) -> ConversationControllerLifecycleTransition {
        lifecycleGeneration += 1
        isHostActive = state == .active
        let conversationOperation = beginConversationOperation()
        if state == .background {
            disableContinuousVoiceActivation()
        }
        return ConversationControllerLifecycleTransition(
            generation: lifecycleGeneration,
            state: state,
            conversationOperation: conversationOperation
        )
    }

    func isHostLifecycleCurrent(_ generation: Int) -> Bool {
        !isShutdown && generation == lifecycleGeneration
    }

    mutating func beginContinuousVoiceActivation() -> Int {
        continuousVoiceActivationGeneration += 1
        activeContinuousVoiceActivation = continuousVoiceActivationGeneration
        return continuousVoiceActivationGeneration
    }

    mutating func disableContinuousVoiceActivation() {
        continuousVoiceActivationGeneration += 1
        activeContinuousVoiceActivation = nil
    }

    func isContinuousVoiceActivationCurrent(_ generation: Int) -> Bool {
        !isShutdown
            && activeContinuousVoiceActivation == generation
            && continuousVoiceActivationGeneration == generation
            && isHostActive
    }

    /// Reserves terminal ownership synchronously. The caller then performs and awaits cleanup.
    @discardableResult
    mutating func beginShutdown() -> Bool {
        guard !isShutdown else { return false }
        isShutdown = true
        isHostActive = false
        lifecycleGeneration += 1
        _ = beginConversationOperation()
        disableContinuousVoiceActivation()
        return true
    }
}
