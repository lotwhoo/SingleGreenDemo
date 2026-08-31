import XCTest
@testable import SingleGreenGlassesKit

final class ReadingPositionEngineTests: XCTestCase {
    func testScriptVersionIsStableForEqualContentAndChangesWithContent() throws {
        let first = try TeleprompterScript("第一句。第二句。")
        let same = try TeleprompterScript("第一句。第二句。")
        let changed = try TeleprompterScript("第一句。第三句。")

        XCTAssertEqual(first.version, same.version)
        XCTAssertNotEqual(first.version, changed.version)
    }

    func testUniqueExactPartialJumpsAtFiftiethNormalizedCharacter() throws {
        let script = try TeleprompterScript(
            String(repeating: "甲", count: 50) + "目标内容继续。"
        )
        let evaluation = ReadingPositionEngine().evaluate(input(
            script: script,
            transcript: "目标内容",
            semantics: .partial
        ))

        guard case .jump(let target, let distance, let confidence, let evidence) =
            evaluation.decision else {
            return XCTFail("Expected an exact forward jump")
        }
        XCTAssertEqual(target.sentenceIndex, 0)
        XCTAssertGreaterThan(target.utf16Offset, 50)
        XCTAssertEqual(distance, TeleprompterLimits.maximumAlignmentLookahead)
        XCTAssertEqual(confidence, 1)
        XCTAssertEqual(evidence, .uniqueExactSuffix)
        XCTAssertEqual(evaluation.nextStability, ReadingPositionStability())
    }

    func testUniqueExactFinalHoldsBeyondFiftiethNormalizedCharacter() throws {
        let script = try TeleprompterScript(
            String(repeating: "甲", count: 51) + "目标内容继续。"
        )
        let evaluation = ReadingPositionEngine().evaluate(input(
            script: script,
            transcript: "目标内容",
            semantics: .final
        ))

        XCTAssertEqual(evaluation.decision, .stay(reason: .noReliableMatch))
    }

    func testAmbiguousExactTargetHoldsForPartialAndFinal() throws {
        let script = try TeleprompterScript("开场目标内容过渡目标内容结束。")
        let engine = ReadingPositionEngine()

        for semantics in [ReadingRecognitionEventSemantics.partial, .final] {
            let evaluation = engine.evaluate(input(
                script: script,
                transcript: "目标内容",
                semantics: semantics
            ))
            XCTAssertEqual(
                evaluation.decision,
                .stay(reason: .ambiguousExactMatch)
            )
            XCTAssertEqual(evaluation.nextStability, ReadingPositionStability())
        }
    }

    func testPartialRequiresStableEvidenceButFinalAdvancesImmediately() throws {
        let script = try TeleprompterScript("第一句从这里开始。第二句现在开始。")
        let engine = ReadingPositionEngine()
        let first = engine.evaluate(input(
            script: script,
            transcript: "第一句从这里开始",
            semantics: .partial
        ))

        guard case .advance(let progressed, _, .sentenceProgress) = first.decision else {
            return XCTFail("Expected first partial to move only within the sentence")
        }
        XCTAssertEqual(progressed.sentenceIndex, 0)
        XCTAssertGreaterThan(progressed.utf16Offset, 0)
        XCTAssertEqual(first.nextStability.candidateSentenceIndex, 1)
        XCTAssertEqual(first.nextStability.candidateUTF16Offset, 0)
        XCTAssertEqual(first.nextStability.observationCount, 1)

        let second = engine.evaluate(
            input(
                script: script,
                anchor: progressed,
                transcript: "第一句从这里开始",
                semantics: .partial
            ),
            stability: first.nextStability
        )
        XCTAssertEqual(
            second.decision,
            .advance(
                target: ReadingPositionAnchor(sentenceIndex: 1, utf16Offset: 0),
                confidence: 1,
                evidence: .stabilizedPartial
            )
        )

        let final = engine.evaluate(input(
            script: script,
            transcript: "第一句从这里开始",
            semantics: .final
        ))
        XCTAssertEqual(
            final.decision,
            .advance(
                target: ReadingPositionAnchor(sentenceIndex: 1, utf16Offset: 0),
                confidence: 1,
                evidence: .finalEvent
            )
        )
    }

    func testDifferentNumericCandidateDoesNotReusePartialStability() throws {
        let script = try TeleprompterScript("第一句从这里开始。第二句现在开始。第三句继续。")
        let version = script.version
        let staleCandidate = ReadingPositionStability(
            scriptVersion: version,
            candidate: ReadingPositionAnchor(sentenceIndex: 2, utf16Offset: 0),
            observationCount: 1
        )
        let evaluation = ReadingPositionEngine().evaluate(
            input(
                script: script,
                transcript: "第一句从这里开始",
                semantics: .partial
            ),
            stability: staleCandidate
        )

        XCTAssertEqual(evaluation.nextStability.candidateSentenceIndex, 1)
        XCTAssertEqual(evaluation.nextStability.candidateUTF16Offset, 0)
        XCTAssertEqual(evaluation.nextStability.observationCount, 1)
    }

    func testStaleScriptVersionFailsClosedWithoutTextEvidence() throws {
        let script = try TeleprompterScript("第一句从这里开始。")
        let staleVersion = TeleprompterScriptVersion(rawValue: script.version.rawValue ^ 1)
        let evaluation = ReadingPositionEngine().evaluate(ReadingPositionInput(
            script: script,
            scriptVersion: staleVersion,
            anchor: ReadingPositionAnchor(sentenceIndex: 0, utf16Offset: 0),
            transcriptFragment: "绝不应该出现在证据里",
            eventSemantics: .final
        ))

        XCTAssertEqual(evaluation.decision, .stay(reason: .staleScriptVersion))
        let renderedDecision = String(reflecting: evaluation.decision)
        XCTAssertFalse(renderedDecision.contains("第一句"))
        XCTAssertFalse(renderedDecision.contains("绝不应该"))
    }

    func testEvaluationIsDeterministicAcrossConcurrentScheduling() async throws {
        let script = try TeleprompterScript("开场过渡内容。用户开始朗读目标内容然后继续。")
        let engine = ReadingPositionEngine()
        let value = input(
            script: script,
            transcript: "目标内容然后",
            semantics: .partial
        )
        let expected = engine.evaluate(value)

        let evaluations = await withTaskGroup(
            of: ReadingPositionEvaluation.self,
            returning: [ReadingPositionEvaluation].self
        ) { group in
            for _ in 0..<64 {
                group.addTask { engine.evaluate(value) }
            }
            var results: [ReadingPositionEvaluation] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(evaluations.count, 64)
        XCTAssertTrue(evaluations.allSatisfy { $0 == expected })
    }

    func testAutomaticJumpUndoStateConsumesOnceAndChecksEveryCompatibilityMarker() throws {
        let script = try TeleprompterScript("第一句。第二句。")
        let source = ReadingPositionAnchor(sentenceIndex: 0, utf16Offset: 0)
        let target = ReadingPositionAnchor(sentenceIndex: 1, utf16Offset: 2)
        var undo = ReadingPositionUndoState()

        undo.record(
            scriptVersion: script.version,
            alignmentGeneration: 7,
            source: source,
            target: target
        )
        XCTAssertTrue(undo.isAvailable(
            scriptVersion: script.version,
            alignmentGeneration: 7,
            currentAnchor: target
        ))
        XCTAssertEqual(undo.consume(
            scriptVersion: script.version,
            alignmentGeneration: 7,
            currentAnchor: target
        ), source)
        XCTAssertNil(undo.consume(
            scriptVersion: script.version,
            alignmentGeneration: 7,
            currentAnchor: target
        ))

        for incompatible in [
            (TeleprompterScriptVersion(rawValue: script.version.rawValue ^ 1), UInt64(7), target),
            (script.version, UInt64(8), target),
            (script.version, UInt64(7), source)
        ] {
            undo.record(
                scriptVersion: script.version,
                alignmentGeneration: 7,
                source: source,
                target: target
            )
            XCTAssertNil(undo.consume(
                scriptVersion: incompatible.0,
                alignmentGeneration: incompatible.1,
                currentAnchor: incompatible.2
            ))
            XCTAssertNil(undo.automaticJump)
        }
    }

    private func input(
        script: TeleprompterScript,
        anchor: ReadingPositionAnchor = .init(sentenceIndex: 0, utf16Offset: 0),
        transcript: String,
        semantics: ReadingRecognitionEventSemantics
    ) -> ReadingPositionInput {
        ReadingPositionInput(
            script: script,
            scriptVersion: script.version,
            anchor: anchor,
            transcriptFragment: transcript,
            eventSemantics: semantics
        )
    }
}
