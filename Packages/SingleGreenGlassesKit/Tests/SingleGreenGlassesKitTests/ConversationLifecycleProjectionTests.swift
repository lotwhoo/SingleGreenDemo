import VoiceChatDomain
import XCTest
@testable import SingleGreenGlassesKit

final class ConversationLifecycleProjectionTests: XCTestCase {
    func testLiveTranscriptAndDisplayedReplyTakePrecedenceOverDomainFallbacks() {
        var conversation = ConversationState()
        conversation.appendUser("历史问题")
        let replyID = conversation.beginReply()
        XCTAssertTrue(conversation.appendReplyDelta(id: replyID, delta: "历史回答"))
        XCTAssertTrue(conversation.completeReply(id: replyID))

        XCTAssertEqual(
            ConversationLifecycleProjection.transcript(
                liveText: "  当前问题  ",
                conversation: conversation
            ),
            "当前问题"
        )
        XCTAssertEqual(
            ConversationLifecycleProjection.assistantReply(
                displayedReply: "当前回答",
                conversation: conversation
            ),
            "当前回答"
        )
    }

    func testProjectionDerivesFailureBeforeCompletedFallback() {
        var conversation = ConversationState()
        conversation.appendUser("问题")
        let replyID = conversation.beginReply()
        XCTAssertTrue(conversation.appendReplyDelta(id: replyID, delta: "回答"))
        XCTAssertTrue(conversation.completeReply(id: replyID))

        XCTAssertEqual(
            ConversationLifecycleProjection.voiceState(
                conversation: conversation,
                assistantReply: "回答",
                error: "失败"
            ),
            .failed
        )
    }

    func testProjectionDistinguishesLocalArmedFromRecognizerStreaming() {
        let armed = ConversationState(inputState: .armed)
        let recording = ConversationState(inputState: .recording)

        XCTAssertEqual(
            ConversationLifecycleProjection.voiceState(
                conversation: armed,
                assistantReply: "",
                error: nil
            ),
            .armed
        )
        XCTAssertEqual(
            ConversationLifecycleProjection.voiceState(
                conversation: recording,
                assistantReply: "",
                error: nil
            ),
            .listening
        )

        let snapshot = ConversationLifecycleProjection.makeSnapshot(
            revision: 1,
            state: .armed,
            transcript: "",
            assistantReply: "",
            audioLevel: 0.25,
            error: nil
        )
        XCTAssertEqual(snapshot.primaryActionTitle, "停止聆听")
        XCTAssertEqual(snapshot.controlState?.statusTitle, "本地聆听中")
        XCTAssertEqual(snapshot.eventDescription, VoiceConversationState.armed.rawValue)
    }
}
