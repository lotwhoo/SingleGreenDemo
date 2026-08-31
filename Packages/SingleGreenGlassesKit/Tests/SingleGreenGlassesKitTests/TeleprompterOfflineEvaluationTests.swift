import Foundation
@testable import TeleprompterEvaluationSupport
import XCTest

final class TeleprompterOfflineEvaluationTests: XCTestCase {
    func testSyntheticCatalogCoversRequiredCategoriesAndBoundaries() {
        let scenarios = TeleprompterSyntheticFixtureCatalog.makeScenarios()
        let ids = Set(scenarios.map(\.id))
        let requiredIDs: Set<String> = [
            "normal", "omission", "insertion", "filler",
            "jump-10", "jump-30", "jump-50", "jump-51",
            "repeated-phrase", "repeated-sentence", "partial-revision",
            "cumulative-transcript", "incremental-transcript", "cross-session",
            "silence", "noise-placeholder", "mixed-language-number",
            "maximum-script", "long-session-30m", "long-session-60m"
        ]

        XCTAssertEqual(ids, requiredIDs)
        XCTAssertEqual(
            scenarios.first { $0.id == "maximum-script" }?.scriptSource.count,
            20_000
        )
        XCTAssertEqual(
            scenarios.reduce(0) { $0 + Int($1.simulatedDurationSeconds) },
            5_400
        )
    }

    func testEvaluationProducesMetricBaselineWithoutSourceOrTranscriptPayload() throws {
        let scenarios = TeleprompterSyntheticFixtureCatalog.makeScenarios()
        let report = try TeleprompterOfflineEvaluator().evaluate(
            scenarios,
            memorySampler: { 12_345 }
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.scenarioCount, 20)
        XCTAssertGreaterThan(report.evaluationCount, 5_400)
        XCTAssertEqual(report.peakResidentMemoryBytes, 12_345)
        XCTAssertEqual(report.simulatedDurationSeconds, 5_400)
        XCTAssertLessThanOrEqual(report.p50DecisionNanoseconds, report.p95DecisionNanoseconds)
        XCTAssertEqual(report.scenarios.map(\.id), scenarios.map(\.id))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try XCTUnwrap(String(
            data: encoder.encode(report),
            encoding: .utf8
        ))
        XCTAssertFalse(encoded.contains("欢迎来到产品发布会"))
        XCTAssertFalse(encoded.contains("AI眼镜2026正式发布"))
        XCTAssertFalse(encoded.contains("transcriptFragment"))
        XCTAssertFalse(encoded.contains("scriptSource"))
        XCTAssertFalse(encoded.contains("provider"))
        XCTAssertFalse(encoded.contains("filePath"))
    }

    func testEvaluatorCountsFalseAndMissedJumpsWithoutThresholdGate() throws {
        let source = "天地玄黄宇宙洪荒日月盈昃辰宿列张。"
        let scenarios = [
            TeleprompterEvaluationScenario(
                id: "expected-jump-but-no-match",
                category: "漏跃迁计数",
                scriptSource: source,
                events: [
                    .init(
                        transcriptFragment: "完全无关",
                        semantics: .final,
                        expectedDecision: .jump,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 8)
                    )
                ]
            ),
            TeleprompterEvaluationScenario(
                id: "unexpected-jump",
                category: "误跃迁计数",
                scriptSource: source,
                events: [
                    .init(
                        transcriptFragment: "日月盈昃",
                        semantics: .final,
                        expectedDecision: .stay
                    )
                ]
            )
        ]

        let report = try TeleprompterOfflineEvaluator().evaluate(scenarios)

        XCTAssertEqual(report.expectedJumpCount, 1)
        XCTAssertEqual(report.missedJumpCount, 1)
        XCTAssertEqual(report.falseJumpCount, 1)
        XCTAssertEqual(report.missedJumpRate, 1)
        XCTAssertEqual(report.falseJumpRate, 1)
        XCTAssertGreaterThan(report.maximumPositionErrorUTF16, 0)
    }

    func testEvaluatorRejectsNonStayExpectationWithoutTarget() {
        let scenario = TeleprompterEvaluationScenario(
            id: "missing-target",
            category: "fixture validation",
            scriptSource: "第一句。第二句。",
            events: [
                .init(
                    transcriptFragment: "第一句",
                    semantics: .final,
                    expectedDecision: .advance
                )
            ]
        )

        XCTAssertThrowsError(try TeleprompterOfflineEvaluator().evaluate([scenario])) { error in
            XCTAssertEqual(
                error as? TeleprompterOfflineEvaluationError,
                .missingExpectedTarget(scenarioID: "missing-target", eventIndex: 0)
            )
        }
    }
}
