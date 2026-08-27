import XCTest
@testable import VoiceChatDomain

final class ConversationStateTests: XCTestCase {
    func testInitializerRestoresActiveReplyIdentity() {
        let requestingID = UUID()
        let searchingID = UUID()

        let requesting = ConversationState(replyState: .requesting(requestingID))
        let searching = ConversationState(replyState: .searching(searchingID))
        let completed = ConversationState(replyState: .completed(UUID()))

        XCTAssertEqual(requesting.activeReplyID, requestingID)
        XCTAssertEqual(searching.activeReplyID, searchingID)
        XCTAssertNil(completed.activeReplyID)
    }

    func testAppendUserCreatesCompletedUserMessage() {
        var state = ConversationState()

        state.appendUser("你好")

        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].text, "你好")
        XCTAssertTrue(state.messages[0].isUser)
        XCTAssertEqual(state.messages[0].status, .completed)
    }

    func testBeginReplyCreatesPendingMessage() {
        let id = UUID()
        var state = ConversationState()

        state.beginReply(id: id)

        XCTAssertEqual(state.activeReplyID, id)
        XCTAssertEqual(state.replyState, .requesting(id))
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages[0].id, id)
        XCTAssertEqual(state.messages[0].text, "")
        XCTAssertFalse(state.messages[0].isUser)
        XCTAssertEqual(state.messages[0].status, .pending)
    }

    func testCancelRemovesOnlyPendingReply() {
        let userID = UUID()
        let replyID = UUID()
        var state = ConversationState(messages: [ChatMessage(text: "问题", isUser: true, id: userID)])
        state.beginReply(id: replyID)

        state.cancelActiveReply()

        XCTAssertEqual(state.messages.map(\.id), [userID])
        XCTAssertEqual(state.replyState, .cancelled(replyID))
        XCTAssertNil(state.activeReplyID)
    }

    func testOldReplyCannotOverwriteNewReply() {
        let oldID = UUID()
        let newID = UUID()
        var state = ConversationState()
        state.beginReply(id: oldID)
        state.beginReply(id: newID)

        XCTAssertFalse(state.completeReply(id: oldID, text: "旧答案"))
        XCTAssertTrue(state.completeReply(id: newID, text: "新答案"))
        XCTAssertEqual(state.messages.map(\.text), ["新答案"])
    }

    func testSearchStateBelongsToActiveReply() {
        let activeID = UUID()
        var state = ConversationState()
        state.beginReply(id: activeID)

        state.markSearching(id: UUID())
        XCTAssertEqual(state.replyState, .requesting(activeID))

        state.markSearching(id: activeID)
        XCTAssertEqual(state.replyState, .searching(activeID))
    }

    func testFailedReplyIsRemovedAndRecorded() {
        let id = UUID()
        var state = ConversationState()
        state.beginReply(id: id)

        XCTAssertTrue(state.failReply(id: id, message: "网络错误"))
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.replyState, .failed(id, "网络错误"))
    }

    func testStaleFailureCannotRemoveActiveReply() {
        let activeID = UUID()
        var state = ConversationState()
        state.beginReply(id: activeID)

        XCTAssertFalse(state.failReply(id: UUID(), message: "旧错误"))
        XCTAssertEqual(state.activeReplyID, activeID)
        XCTAssertEqual(state.replyState, .requesting(activeID))
        XCTAssertEqual(state.messages.map(\.id), [activeID])
    }

    func testInactiveCompletionDoesNotMutateMessages() {
        let message = ChatMessage(text: "已有回答", isUser: false)
        var state = ConversationState(messages: [message])

        XCTAssertFalse(state.completeReply(id: message.id, text: "被覆盖"))
        XCTAssertEqual(state.messages, [message])
        XCTAssertEqual(state.replyState, .idle)
    }

    func testCancelWithoutActiveReplyIsNoOp() {
        let message = ChatMessage(text: "保留", isUser: true)
        var state = ConversationState(messages: [message])

        XCTAssertNil(state.cancelActiveReply())
        XCTAssertEqual(state.messages, [message])
        XCTAssertEqual(state.replyState, .idle)
    }
}
