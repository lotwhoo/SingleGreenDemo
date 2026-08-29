import XCTest
@testable import SingleGreenGlassesKit

final class ConversationControllerExecutionStateTests: XCTestCase {
    func testNewConversationOperationInvalidatesPreviousOperation() {
        var state = ConversationControllerExecutionState()

        let first = state.beginConversationOperation()
        let second = state.beginConversationOperation()

        XCTAssertFalse(state.isConversationOperationCurrent(first))
        XCTAssertTrue(state.isConversationOperationCurrent(second))
    }

    func testBackgroundTransitionInvalidatesContinuousActivationAndRequiresInactiveChecks() {
        var state = ConversationControllerExecutionState()
        let continuous = state.beginContinuousVoiceActivation()

        let transition = state.beginHostLifecycleTransition(.background)

        XCTAssertEqual(transition.state, .background)
        XCTAssertTrue(state.isHostLifecycleCurrent(transition.generation))
        XCTAssertFalse(state.isContinuousVoiceActivationCurrent(continuous))
        XCTAssertFalse(state.isConversationOperationCurrent(transition.conversationOperation))
        XCTAssertTrue(state.isConversationOperationCurrent(
            transition.conversationOperation,
            requiresActiveHost: false
        ))
    }

    func testForegroundTransitionIsPassiveButInvalidatesOlderLifecycleAndOperation() {
        var state = ConversationControllerExecutionState()
        let background = state.beginHostLifecycleTransition(.background)

        let foreground = state.beginHostLifecycleTransition(.active)

        XCTAssertFalse(state.isHostLifecycleCurrent(background.generation))
        XCTAssertTrue(state.isHostLifecycleCurrent(foreground.generation))
        XCTAssertFalse(state.isConversationOperationCurrent(background.conversationOperation))
        XCTAssertTrue(state.isConversationOperationCurrent(foreground.conversationOperation))
    }

    func testStartingNewContinuousActivationInvalidatesPreviousGeneration() {
        var state = ConversationControllerExecutionState()

        let first = state.beginContinuousVoiceActivation()
        let second = state.beginContinuousVoiceActivation()

        XCTAssertFalse(state.isContinuousVoiceActivationCurrent(first))
        XCTAssertTrue(state.isContinuousVoiceActivationCurrent(second))
    }

    func testExplicitDisableInvalidatesContinuousActivation() {
        var state = ConversationControllerExecutionState()
        let generation = state.beginContinuousVoiceActivation()

        state.disableContinuousVoiceActivation()

        XCTAssertNil(state.activeContinuousVoiceActivation)
        XCTAssertFalse(state.isContinuousVoiceActivationCurrent(generation))
    }

    func testShutdownAdmissionIsIdempotentAndInvalidatesAllWork() {
        var state = ConversationControllerExecutionState()
        let operation = state.beginConversationOperation()
        let lifecycle = state.beginHostLifecycleTransition(.active)
        let continuous = state.beginContinuousVoiceActivation()

        XCTAssertTrue(state.beginShutdown())
        let terminalState = state

        XCTAssertFalse(state.isConversationOperationCurrent(operation, requiresActiveHost: false))
        XCTAssertFalse(state.isHostLifecycleCurrent(lifecycle.generation))
        XCTAssertFalse(state.isContinuousVoiceActivationCurrent(continuous))
        XCTAssertFalse(state.beginShutdown())
        XCTAssertEqual(state, terminalState)
    }
}
