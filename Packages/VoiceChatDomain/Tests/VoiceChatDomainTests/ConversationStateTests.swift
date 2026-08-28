import XCTest
@testable import VoiceChatDomain

final class ConversationStateTests: XCTestCase {
    func testArmedInputStateIsPreservedByValueSemantics() {
        let state = ConversationState(inputState: .armed)
        let copy = state

        XCTAssertEqual(state.inputState, .armed)
        XCTAssertEqual(copy, state)
    }

    func testInitializerRestoresActiveReplyIdentity() {
        let requestingID = UUID()
        let searchingID = UUID()
        let streamingID = UUID()

        let requesting = ConversationState(replyState: .requesting(requestingID))
        let searching = ConversationState(replyState: .searching(searchingID))
        let streaming = ConversationState(replyState: .streaming(streamingID))
        let completed = ConversationState(replyState: .completed(UUID()))

        XCTAssertEqual(requesting.activeReplyID, requestingID)
        XCTAssertEqual(searching.activeReplyID, searchingID)
        XCTAssertEqual(streaming.activeReplyID, streamingID)
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

    func testReplyDeltasAccumulateInOrderAndRejectStaleID() {
        let id = UUID()
        var state = ConversationState()
        state.beginReply(id: id)

        XCTAssertTrue(state.appendReplyDelta(id: id, delta: "你"))
        XCTAssertTrue(state.appendReplyDelta(id: id, delta: "好"))
        XCTAssertFalse(state.appendReplyDelta(id: UUID(), delta: "旧"))
        XCTAssertEqual(state.messages.first?.text, "你好")
        XCTAssertEqual(state.replyState, .streaming(id))
        XCTAssertTrue(state.completeReply(id: id))
        XCTAssertEqual(state.messages.first?.status, .completed)
    }

    func testFailurePreservesPartialReplyButEmptyFailureRemovesPlaceholder() {
        let partialID = UUID()
        var partial = ConversationState()
        partial.beginReply(id: partialID)
        partial.appendReplyDelta(id: partialID, delta: "部分回答")

        XCTAssertTrue(partial.failReply(id: partialID, message: "中断"))
        XCTAssertEqual(partial.messages.first?.text, "部分回答")
        XCTAssertEqual(partial.messages.first?.status, .failed)
        XCTAssertEqual(partial.replyState, .failed(partialID, "中断"))

        let emptyID = UUID()
        var empty = ConversationState()
        empty.beginReply(id: emptyID)
        XCTAssertTrue(empty.failReply(id: emptyID, message: "失败"))
        XCTAssertTrue(empty.messages.isEmpty)

        let whitespaceID = UUID()
        var whitespace = ConversationState()
        whitespace.beginReply(id: whitespaceID)
        whitespace.appendReplyDelta(id: whitespaceID, delta: "  \n")
        XCTAssertTrue(whitespace.failReply(id: whitespaceID, message: "无有效内容"))
        XCTAssertTrue(whitespace.messages.isEmpty)
    }

    func testCancellingStreamingReplyRemovesPartialAndRejectsLaterDelta() {
        let id = UUID()
        var state = ConversationState()
        state.beginReply(id: id)
        XCTAssertTrue(state.appendReplyDelta(id: id, delta: "部分"))

        XCTAssertEqual(state.cancelActiveReply(), id)
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.replyState, .cancelled(id))
        XCTAssertFalse(state.appendReplyDelta(id: id, delta: "迟到"))
    }

    func testFailureCanExplicitlyDiscardUntrustedPartialReply() {
        let id = UUID()
        var state = ConversationState()
        state.beginReply(id: id)
        state.appendReplyDelta(id: id, delta: "不可信正文")

        XCTAssertTrue(state.failReply(
            id: id,
            message: "mixed content and tool call",
            preservingPartial: false
        ))
        XCTAssertTrue(state.messages.isEmpty)
        XCTAssertEqual(state.replyState, .failed(id, "mixed content and tool call"))
    }

    func testAbortUncommittedTurnPreservesCompletedHistory() {
        let completedUser = ChatMessage(text: "已完成问题", isUser: true)
        let completedReply = ChatMessage(text: "已完成回答", isUser: false)
        var state = ConversationState(messages: [completedUser, completedReply])
        state.appendUser("未提交问题")
        let pendingID = state.beginReply()
        state.appendReplyDelta(id: pendingID, delta: "未提交部分")

        XCTAssertEqual(state.abortUncommittedTurn(), pendingID)
        XCTAssertEqual(state.messages, [completedUser, completedReply])
        XCTAssertEqual(state.replyState, .cancelled(pendingID))
    }
}
