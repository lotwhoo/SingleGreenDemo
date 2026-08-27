import XCTest
@testable import VoiceChatCore

final class ASRSessionTests: XCTestCase {

    func testConfigDefaults() {
        let config = ASRSession.Config(apiKey: "test-key")
        XCTAssertEqual(config.resourceID, "volc.seedasr.sauc.duration")
        XCTAssertEqual(config.host, "openspeech.bytedance.com")
        XCTAssertEqual(config.path, "/api/v3/sauc/bigmodel")
        XCTAssertEqual(config.language, "zh-CN")
        XCTAssertTrue(config.enableITN)
        XCTAssertTrue(config.enablePunc)
        XCTAssertTrue(config.showUtterances)
        XCTAssertTrue(config.hotwords.isEmpty)
        XCTAssertEqual(config.timeoutInterval, 30)
    }

    func testInitialState() {
        let session = ASRSession(config: .init(apiKey: "test"))
        XCTAssertEqual(session.state, .idle)
    }

    func testFinishInIdleIsNoOp() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        await session.finish()
        XCTAssertEqual(session.state, .idle)
    }

    func testCancelInIdleReturnsToIdle() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        await session.cancel()
        XCTAssertEqual(session.state, .idle)
    }

    func testEventsStreamSubscribable() {
        // 事件流应可正常订阅（不崩溃、可取消）
        let session = ASRSession(config: .init(apiKey: "test"))
        let task = Task {
            var count = 0
            for await _ in session.events { count += 1 }
            return count
        }
        task.cancel()
    }

    func testStateReadIsThreadSafe() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        let reads = (0..<50).map { _ in
            Task { _ = session.state }
        }
        for t in reads { _ = await t.value }
        XCTAssertEqual(session.state, .idle)
    }
}
