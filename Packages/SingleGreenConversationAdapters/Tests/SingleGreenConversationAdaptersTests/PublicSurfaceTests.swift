import SingleGreenConversationAdapters
import XCTest

final class PublicSurfaceTests: XCTestCase {
    func testReusableAdapterTypesAreVisibleWithoutTestableImport() {
        XCTAssertNotNil(VoiceChatSpeechRecognitionAdapter.self)
        XCTAssertNotNil(VoiceChatSupervisedSpeechRecognitionAdapter.self)
        XCTAssertNotNil(VoiceChatVoiceActivatedSpeechRecognitionAdapter.self)
        XCTAssertNotNil(LLMKitConversationAgentAdapter.self)

        let policy = LLMKitConversationAgentAdapterPolicy(
            toolActivity: { _ in nil },
            failure: { _ in fatalError("Type-check-only fixture") }
        )

        let makePTT = {
            VoiceChatSpeechRecognitionAdapter(session: typeCheckOnly())
        } as () -> VoiceChatSpeechRecognitionAdapter
        let makeVAD = {
            VoiceChatVoiceActivatedSpeechRecognitionAdapter(
                session: typeCheckOnly()
            )
        } as () -> VoiceChatVoiceActivatedSpeechRecognitionAdapter
        let makeSupervisedPTT = {
            VoiceChatSupervisedSpeechRecognitionAdapter(
                supervisor: typeCheckOnly()
            )
        } as () -> VoiceChatSupervisedSpeechRecognitionAdapter
        let makeAgent = {
            LLMKitConversationAgentAdapter(
                agent: typeCheckOnly(),
                policy: policy
            )
        } as () -> LLMKitConversationAgentAdapter
        XCTAssertNotNil(makePTT as Any)
        XCTAssertNotNil(makeSupervisedPTT as Any)
        XCTAssertNotNil(makeVAD as Any)
        XCTAssertNotNil(makeAgent as Any)
    }
}

private func typeCheckOnly<Value>() -> Value {
    fatalError("Type-check-only fixture")
}
