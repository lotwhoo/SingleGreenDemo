import OSLog
import SingleGreenGlassesKit

@MainActor
final class ConversationTelemetryStore: ConversationTelemetrySink {
    private let logger = Logger(subsystem: "com.local.SingleGreenDemo", category: "conversation")
    private let capacity: Int
    private(set) var events: [ConversationTelemetryEvent] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: ConversationTelemetryEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let failure = event.failureCode?.rawValue ?? "none"
        logger.info(
            "phase=\(event.phase.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) duration_ms=\(event.elapsedMilliseconds, privacy: .public) failure=\(failure, privacy: .public)"
        )
    }
}
