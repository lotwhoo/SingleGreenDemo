@MainActor
final class ConversationTelemetryTracker {
    private let sink: any ConversationTelemetrySink
    private let monotonicNow: () -> UInt64
    private var phaseStartedAt: [ConversationTelemetryPhase: UInt64] = [:]

    init(
        sink: any ConversationTelemetrySink,
        monotonicNow: @escaping () -> UInt64
    ) {
        self.sink = sink
        self.monotonicNow = monotonicNow
    }

    func begin(_ phase: ConversationTelemetryPhase) {
        recordIfActive(phase, outcome: .cancelled)
        phaseStartedAt[phase] = monotonicNow()
        sink.record(.init(
            phase: phase,
            outcome: .started,
            elapsedMilliseconds: 0
        ))
    }

    func record(
        _ phase: ConversationTelemetryPhase,
        outcome: ConversationTelemetryOutcome,
        failure: ConversationFailureCode? = nil
    ) {
        let now = monotonicNow()
        let start = phaseStartedAt.removeValue(forKey: phase) ?? now
        let elapsed = now >= start ? (now - start) / 1_000_000 : 0
        sink.record(.init(
            phase: phase,
            outcome: outcome,
            elapsedMilliseconds: elapsed,
            failureCode: failure
        ))
    }

    func recordIfActive(
        _ phase: ConversationTelemetryPhase,
        outcome: ConversationTelemetryOutcome,
        failure: ConversationFailureCode? = nil
    ) {
        guard phaseStartedAt[phase] != nil else { return }
        record(phase, outcome: outcome, failure: failure)
    }

    func terminateActiveWork(outcome: ConversationTelemetryOutcome) {
        recordIfActive(.preparation, outcome: outcome)
        recordIfActive(.input, outcome: outcome)
        recordIfActive(.display, outcome: outcome)
        recordIfActive(.reply, outcome: outcome)
    }
}
