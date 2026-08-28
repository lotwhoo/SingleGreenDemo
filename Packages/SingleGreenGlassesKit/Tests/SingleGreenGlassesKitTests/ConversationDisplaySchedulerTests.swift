import StreamingTextKit
import XCTest
@testable import SingleGreenGlassesKit

@MainActor
final class ConversationDisplaySchedulerTests: XCTestCase {
    func testStaleOperationCannotAppendOrSettleNewDisplay() {
        let scheduler = makeScheduler()
        let old = ReplyOperation(id: UUID(), generation: 1)
        let current = ReplyOperation(id: UUID(), generation: 2)

        scheduler.begin(old)
        scheduler.append("旧回答", for: old)
        scheduler.begin(current)
        scheduler.append("迟到", for: old)

        XCTAssertEqual(scheduler.targetText, "")
        XCTAssertNil(scheduler.settleFailure(discardPartial: false, for: old))
    }

    func testReconciliationPreservesCombiningScalarSuffix() throws {
        let scheduler = makeScheduler()
        let operation = ReplyOperation(id: UUID(), generation: 1)
        scheduler.begin(operation)
        scheduler.append("e", for: operation)

        let suffix = try scheduler.reconcileAndMarkUpstreamCompleted(
            answer: "e\u{301}",
            accumulated: "e",
            for: operation
        )

        XCTAssertEqual(suffix?.unicodeScalars.map(\.value), [0x301])
        XCTAssertEqual(scheduler.targetText.unicodeScalars.map(\.value), [0x65, 0x301])
    }

    func testFailurePreservesMeaningfulPartialAndDiscardsWhitespace() {
        let scheduler = makeScheduler()
        let first = ReplyOperation(id: UUID(), generation: 1)
        scheduler.begin(first)
        scheduler.append("部分回答", for: first)
        XCTAssertEqual(
            scheduler.settleFailure(discardPartial: false, for: first),
            DisplayFailureResult(visibleText: "部分回答", preservesPartial: true)
        )

        let second = ReplyOperation(id: UUID(), generation: 2)
        scheduler.begin(second)
        scheduler.append(" \n", for: second)
        XCTAssertEqual(
            scheduler.settleFailure(discardPartial: false, for: second),
            DisplayFailureResult(visibleText: "", preservesPartial: false)
        )
    }

    private func makeScheduler() -> ConversationDisplayScheduler {
        ConversationDisplayScheduler(
            policy: .comfortableReading,
            sleep: { _ in throw CancellationError() },
            reduceMotion: { true }
        )
    }
}
