import Combine
import Foundation
import OSLog
import SingleGreenGlassesKit
import UIKit

@MainActor
final class ConversationTelemetryStore: ObservableObject, ConversationTelemetrySink {
    private let logger = Logger(subsystem: "com.local.SingleGreenDemo", category: "conversation")
    private let capacity: Int
    private(set) var events: [ConversationTelemetryEvent] = []
    @Published private(set) var diagnosticLines: [String] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: ConversationTelemetryEvent) {
        #if INTERNAL_DIAGNOSTICS || DEBUG
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let failure = event.failureCode?.rawValue ?? "none"
        logger.info(
            "phase=\(event.phase.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) duration_ms=\(event.elapsedMilliseconds, privacy: .public) failure=\(failure, privacy: .public)"
        )
        record(
            category: "conversation",
            message: "phase=\(event.phase.rawValue) outcome=\(event.outcome.rawValue) duration_ms=\(event.elapsedMilliseconds) failure=\(failure)"
        )
        #else
        _ = event
        #endif
    }

    func record(category: String, message: String) {
        #if INTERNAL_DIAGNOSTICS
        let timestamp = ISO8601DateFormatter().string(from: Date())
        diagnosticLines.append("\(timestamp) [\(category)] \(message)")
        if diagnosticLines.count > capacity {
            diagnosticLines.removeFirst(diagnosticLines.count - capacity)
        }
        #else
        _ = category
        _ = message
        #endif
    }

    func removeAllDiagnostics() {
        #if INTERNAL_DIAGNOSTICS
        diagnosticLines.removeAll(keepingCapacity: true)
        #endif
    }

    func makeExportURL() throws -> URL {
        #if INTERNAL_DIAGNOSTICS
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let header = [
            "SingleGreenDemo diagnostics",
            "version=\(version) build=\(build)",
            "system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "model=\(UIDevice.current.model)",
            "exported_at=\(ISO8601DateFormatter().string(from: Date()))",
            "entries=\(diagnosticLines.count)",
            ""
        ]
        let contents = (header + diagnosticLines).joined(separator: "\n")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleGreenDemo-logs-\(formatter.string(from: Date())).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
        #else
        throw DiagnosticsExportError.unavailable
        #endif
    }
}

enum DiagnosticsExportError: Error {
    case unavailable
}
