import Foundation
import SingleGreenGlassesKit

public enum TeleprompterExpectedDecision: String, Codable, Equatable, Sendable {
    case stay
    case advance
    case jump
}

public struct TeleprompterEvaluationEvent: Sendable {
    public let transcriptFragment: String
    public let semantics: ReadingRecognitionEventSemantics
    public let expectedDecision: TeleprompterExpectedDecision
    public let expectedTarget: ReadingPositionAnchor?
    public let resetsSessionStability: Bool

    public init(
        transcriptFragment: String,
        semantics: ReadingRecognitionEventSemantics,
        expectedDecision: TeleprompterExpectedDecision,
        expectedTarget: ReadingPositionAnchor? = nil,
        resetsSessionStability: Bool = false
    ) {
        self.transcriptFragment = transcriptFragment
        self.semantics = semantics
        self.expectedDecision = expectedDecision
        self.expectedTarget = expectedTarget
        self.resetsSessionStability = resetsSessionStability
    }
}

public struct TeleprompterEvaluationScenario: Sendable {
    public let id: String
    public let category: String
    public let scriptSource: String
    public let initialAnchor: ReadingPositionAnchor
    public let events: [TeleprompterEvaluationEvent]
    public let repetitions: Int
    public let simulatedDurationSeconds: Double

    public init(
        id: String,
        category: String,
        scriptSource: String,
        initialAnchor: ReadingPositionAnchor = .init(sentenceIndex: 0, utf16Offset: 0),
        events: [TeleprompterEvaluationEvent],
        repetitions: Int = 1,
        simulatedDurationSeconds: Double = 0
    ) {
        self.id = id
        self.category = category
        self.scriptSource = scriptSource
        self.initialAnchor = initialAnchor
        self.events = events
        self.repetitions = max(1, repetitions)
        self.simulatedDurationSeconds = max(0, simulatedDurationSeconds)
    }
}

public enum TeleprompterOfflineEvaluationError: Error, Equatable, Sendable {
    case missingExpectedTarget(scenarioID: String, eventIndex: Int)
}

public struct TeleprompterEvaluationScenarioSummary: Codable, Equatable, Sendable {
    public let id: String
    public let category: String
    public let evaluationCount: Int
    public let falseJumpCount: Int
    public let missedJumpCount: Int
    public let wrongDecisionCount: Int
    public let meanPositionErrorUTF16: Double
    public let maximumPositionErrorUTF16: Int
    public let stateUpdateCount: Int
}

public struct TeleprompterOfflineEvaluationReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let scenarioCount: Int
    public let evaluationCount: Int
    public let expectedJumpCount: Int
    public let actualJumpCount: Int
    public let falseJumpCount: Int
    public let missedJumpCount: Int
    public let wrongDecisionCount: Int
    public let falseJumpRate: Double
    public let missedJumpRate: Double
    public let meanPositionErrorUTF16: Double
    public let maximumPositionErrorUTF16: Int
    public let p50DecisionNanoseconds: UInt64
    public let p95DecisionNanoseconds: UInt64
    public let peakResidentMemoryBytes: UInt64
    public let stateUpdateCount: Int
    public let stateUpdatesPerSimulatedMinute: Double
    public let simulatedDurationSeconds: Double
    public let scenarios: [TeleprompterEvaluationScenarioSummary]
}

public struct TeleprompterOfflineEvaluator: Sendable {
    private let engine = ReadingPositionEngine()

    public init() {}

    public func evaluate(
        _ scenarios: [TeleprompterEvaluationScenario],
        memorySampler: @Sendable () -> UInt64 = { 0 }
    ) throws -> TeleprompterOfflineEvaluationReport {
        var aggregate = MutableEvaluationMetrics()
        var summaries: [TeleprompterEvaluationScenarioSummary] = []

        for scenario in scenarios {
            let script = try TeleprompterScript(
                scenario.scriptSource,
                identity: .init(rawValue: "offline-evaluation-\(scenario.id)")
            )
            var scenarioMetrics = MutableEvaluationMetrics()
            var anchor = scenario.initialAnchor
            var stability = ReadingPositionStability()

            for _ in 0..<scenario.repetitions {
                for (eventIndex, event) in scenario.events.enumerated() {
                    if event.expectedDecision != .stay, event.expectedTarget == nil {
                        throw TeleprompterOfflineEvaluationError.missingExpectedTarget(
                            scenarioID: scenario.id,
                            eventIndex: eventIndex
                        )
                    }
                    if event.resetsSessionStability { stability = ReadingPositionStability() }
                    let started = ContinuousClock.now
                    let result = engine.evaluate(
                        ReadingPositionInput(
                            script: script,
                            scriptVersion: script.version,
                            anchor: anchor,
                            transcriptFragment: event.transcriptFragment,
                            eventSemantics: event.semantics
                        ),
                        stability: stability
                    )
                    let elapsed = started.duration(to: .now)
                    stability = result.nextStability
                    let actual = Self.actualDecision(result.decision, fallback: anchor)
                    let expectedTarget = event.expectedTarget ?? anchor
                    let positionError = abs(
                        Self.linearUTF16Offset(actual.target, in: script)
                            - Self.linearUTF16Offset(expectedTarget, in: script)
                    )
                    let expectedJump = event.expectedDecision == .jump
                    let actualJump = actual.kind == .jump
                    let wrongDecision = actual.kind != event.expectedDecision
                    let stateUpdated = actual.target != anchor
                    let durationNanoseconds = Self.nanoseconds(elapsed)
                    let peakResidentMemoryBytes = memorySampler()

                    scenarioMetrics.record(
                        expectedJump: expectedJump,
                        actualJump: actualJump,
                        wrongDecision: wrongDecision,
                        positionError: positionError,
                        durationNanoseconds: durationNanoseconds,
                        peakResidentMemoryBytes: peakResidentMemoryBytes,
                        stateUpdated: stateUpdated
                    )
                    aggregate.record(
                        expectedJump: expectedJump,
                        actualJump: actualJump,
                        wrongDecision: wrongDecision,
                        positionError: positionError,
                        durationNanoseconds: durationNanoseconds,
                        peakResidentMemoryBytes: peakResidentMemoryBytes,
                        stateUpdated: stateUpdated
                    )
                    anchor = actual.target
                }
            }

            aggregate.simulatedDurationSeconds += scenario.simulatedDurationSeconds
            summaries.append(scenarioMetrics.summary(id: scenario.id, category: scenario.category))
        }

        return aggregate.report(scenarioCount: scenarios.count, summaries: summaries)
    }

    private static func actualDecision(
        _ decision: ReadingPositionDecision,
        fallback: ReadingPositionAnchor
    ) -> (kind: TeleprompterExpectedDecision, target: ReadingPositionAnchor) {
        switch decision {
        case .stay:
            return (.stay, fallback)
        case .advance(let target, _, _):
            return (.advance, target)
        case .jump(let target, _, _, _):
            return (.jump, target)
        }
    }

    private static func linearUTF16Offset(
        _ anchor: ReadingPositionAnchor,
        in script: TeleprompterScript
    ) -> Int {
        let safeSentence = min(anchor.sentenceIndex, script.sentences.count - 1)
        let prefix = script.sentences[..<safeSentence].reduce(0) {
            $0 + ($1 as NSString).length + 1
        }
        let sentenceLength = (script.sentences[safeSentence] as NSString).length
        return prefix + min(anchor.utf16Offset, sentenceLength)
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let secondsNanoseconds = UInt64(seconds) * 1_000_000_000
        let fractionalNanoseconds = UInt64(attoseconds / 1_000_000_000)
        return secondsNanoseconds + fractionalNanoseconds
    }
}

private struct MutableEvaluationMetrics {
    var evaluationCount = 0
    var expectedJumpCount = 0
    var actualJumpCount = 0
    var falseJumpCount = 0
    var missedJumpCount = 0
    var wrongDecisionCount = 0
    var totalPositionErrorUTF16 = 0
    var maximumPositionErrorUTF16 = 0
    var decisionNanoseconds: [UInt64] = []
    var peakResidentMemoryBytes: UInt64 = 0
    var stateUpdateCount = 0
    var simulatedDurationSeconds: Double = 0

    mutating func record(
        expectedJump: Bool,
        actualJump: Bool,
        wrongDecision: Bool,
        positionError: Int,
        durationNanoseconds: UInt64,
        peakResidentMemoryBytes: UInt64,
        stateUpdated: Bool
    ) {
        evaluationCount += 1
        if expectedJump { expectedJumpCount += 1 }
        if actualJump { actualJumpCount += 1 }
        if actualJump && !expectedJump { falseJumpCount += 1 }
        if expectedJump && !actualJump { missedJumpCount += 1 }
        if wrongDecision { wrongDecisionCount += 1 }
        totalPositionErrorUTF16 += positionError
        maximumPositionErrorUTF16 = max(maximumPositionErrorUTF16, positionError)
        decisionNanoseconds.append(durationNanoseconds)
        self.peakResidentMemoryBytes = max(
            self.peakResidentMemoryBytes,
            peakResidentMemoryBytes
        )
        if stateUpdated { stateUpdateCount += 1 }
    }

    func summary(id: String, category: String) -> TeleprompterEvaluationScenarioSummary {
        TeleprompterEvaluationScenarioSummary(
            id: id,
            category: category,
            evaluationCount: evaluationCount,
            falseJumpCount: falseJumpCount,
            missedJumpCount: missedJumpCount,
            wrongDecisionCount: wrongDecisionCount,
            meanPositionErrorUTF16: meanPositionErrorUTF16,
            maximumPositionErrorUTF16: maximumPositionErrorUTF16,
            stateUpdateCount: stateUpdateCount
        )
    }

    func report(
        scenarioCount: Int,
        summaries: [TeleprompterEvaluationScenarioSummary]
    ) -> TeleprompterOfflineEvaluationReport {
        TeleprompterOfflineEvaluationReport(
            schemaVersion: TeleprompterOfflineEvaluationReport.schemaVersion,
            scenarioCount: scenarioCount,
            evaluationCount: evaluationCount,
            expectedJumpCount: expectedJumpCount,
            actualJumpCount: actualJumpCount,
            falseJumpCount: falseJumpCount,
            missedJumpCount: missedJumpCount,
            wrongDecisionCount: wrongDecisionCount,
            falseJumpRate: rate(falseJumpCount, denominator: actualJumpCount),
            missedJumpRate: rate(missedJumpCount, denominator: expectedJumpCount),
            meanPositionErrorUTF16: meanPositionErrorUTF16,
            maximumPositionErrorUTF16: maximumPositionErrorUTF16,
            p50DecisionNanoseconds: percentile(0.50),
            p95DecisionNanoseconds: percentile(0.95),
            peakResidentMemoryBytes: peakResidentMemoryBytes,
            stateUpdateCount: stateUpdateCount,
            stateUpdatesPerSimulatedMinute: simulatedDurationSeconds > 0
                ? Double(stateUpdateCount) / simulatedDurationSeconds * 60
                : 0,
            simulatedDurationSeconds: simulatedDurationSeconds,
            scenarios: summaries
        )
    }

    private var meanPositionErrorUTF16: Double {
        evaluationCount > 0 ? Double(totalPositionErrorUTF16) / Double(evaluationCount) : 0
    }

    private func rate(_ numerator: Int, denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }

    private func percentile(_ fraction: Double) -> UInt64 {
        guard !decisionNanoseconds.isEmpty else { return 0 }
        let sorted = decisionNanoseconds.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(index, sorted.count - 1)]
    }
}
