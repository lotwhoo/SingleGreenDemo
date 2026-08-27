import CoreGraphics
import XCTest
@testable import StreamingTextKit

final class StreamingTextKitTests: XCTestCase {
    func testBufferPreservesGraphemeBoundariesAndExactText() {
        var buffer = TypewriterTextBuffer()
        buffer.append("你A\n")
        buffer.append("👨‍👩‍👧‍👦")
        buffer.append("e\u{301}")

        var frames: [String] = []
        while !buffer.isCaughtUp {
            XCTAssertTrue(buffer.advance(maxCharacters: 1))
            frames.append(buffer.visibleText)
        }

        XCTAssertEqual(buffer.visibleText, "你A\n👨‍👩‍👧‍👦e\u{301}")
        XCTAssertEqual(frames.map(\.count), [1, 2, 3, 4, 5])
    }

    func testBufferHandlesCombiningScalarAfterVisibleTextCaughtUp() {
        var buffer = TypewriterTextBuffer()
        buffer.append("e")
        XCTAssertTrue(buffer.advance(maxCharacters: 1))

        buffer.append("\u{301}")

        XCTAssertFalse(buffer.isCaughtUp)
        XCTAssertEqual(buffer.pendingCharacterCount, 1)
        XCTAssertTrue(buffer.advance(maxCharacters: buffer.suggestedBatchSize()))
        XCTAssertEqual(buffer.visibleText, "e\u{301}")
    }

    func testStandardPolicyCatchesLargeBacklogWithinFifteenTicks() {
        var buffer = TypewriterTextBuffer()
        buffer.append(String(repeating: "字", count: 200))

        var ticks = 0
        while !buffer.isCaughtUp, ticks < 15 {
            XCTAssertTrue(buffer.advance(maxCharacters: buffer.suggestedBatchSize()))
            ticks += 1
        }

        XCTAssertTrue(buffer.isCaughtUp)
        XCTAssertLessThanOrEqual(ticks, 15)
    }

    func testCustomPolicyCanUpgradeCadenceWithoutChangingBuffer() {
        let policy = TypewriterPolicy(
            tickIntervalMilliseconds: 20,
            shortBacklogLimit: 4,
            mediumBacklogLimit: 8,
            mediumBatchSize: 3,
            minimumLargeBatchSize: 5,
            catchUpTickBudget: 5
        )
        var buffer = TypewriterTextBuffer(policy: policy)
        buffer.append(String(repeating: "x", count: 25))

        XCTAssertEqual(policy.tickIntervalMilliseconds, 20)
        XCTAssertEqual(buffer.suggestedBatchSize(), 5)
    }

    func testPolicyNormalizesInvalidThresholdsWithoutTrapping() {
        let policy = TypewriterPolicy(
            tickIntervalMilliseconds: 0,
            shortBacklogLimit: 0,
            mediumBacklogLimit: 0,
            mediumBatchSize: 0,
            minimumLargeBatchSize: 0,
            catchUpTickBudget: 0
        )
        var buffer = TypewriterTextBuffer(policy: policy)
        buffer.append("ab")

        XCTAssertEqual(policy.tickIntervalMilliseconds, 1)
        XCTAssertEqual(policy.shortBacklogLimit, 1)
        XCTAssertEqual(policy.mediumBacklogLimit, 1)
        XCTAssertEqual(buffer.suggestedBatchSize(), 2)
    }

    func testReconcilerUsesUnicodeScalars() {
        XCTAssertEqual(
            StreamingTextReconciler.suffix(in: "e\u{301}", after: "e"),
            "\u{301}"
        )
        XCTAssertNil(StreamingTextReconciler.suffix(in: "不同", after: "前缀"))
    }

    func testAutoFollowRequiresGrowthAndOverflow() {
        XCTAssertFalse(StreamingTextAutoFollowPolicy.shouldFollow(
            previousContentHeight: 40,
            newContentHeight: 40,
            viewportHeight: 100
        ))
        XCTAssertFalse(StreamingTextAutoFollowPolicy.shouldFollow(
            previousContentHeight: 40,
            newContentHeight: 80,
            viewportHeight: 100
        ))
        XCTAssertTrue(StreamingTextAutoFollowPolicy.shouldFollow(
            previousContentHeight: 96,
            newContentHeight: 120,
            viewportHeight: 100
        ))
    }
}
