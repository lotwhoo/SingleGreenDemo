#if INTERNAL_DIAGNOSTICS
import Combine
import Foundation
import OSLog
import SingleGreenGlassesKit
import UIKit

@MainActor
final class ConversationTelemetryStore:
    ObservableObject,
    ConversationTelemetrySink,
    InternalDiagnosticsLineSink {
    private let logger = Logger(subsystem: "com.local.SingleGreenDemo", category: "conversation")
    private let capacity: Int
    private var diagnosticsBarrierFactories: [
        @Sendable () -> InternalDiagnosticsBarrierHandle
    ] = []
    private var snapshotTransactionActive = false
    private var snapshotTransactionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var events: [ConversationTelemetryEvent] = []
    @Published private(set) var diagnosticLines: [String] = []

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
        record(
            category: "conversation",
            message: "phase=\(event.phase.rawValue) outcome=\(event.outcome.rawValue) duration_ms=\(event.elapsedMilliseconds) failure=\(failure)"
        )
    }

    func record(category: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        diagnosticLines.append("\(timestamp) [\(category)] \(message)")
        if diagnosticLines.count > capacity {
            diagnosticLines.removeFirst(diagnosticLines.count - capacity)
        }
    }

    func registerDiagnosticsBarrierFactory(
        _ factory: @escaping @Sendable () -> InternalDiagnosticsBarrierHandle
    ) {
        diagnosticsBarrierFactories.append(factory)
    }

    func removeAllDiagnostics() async {
        await beginSnapshotTransaction()
        let barriers = diagnosticsBarrierFactories.map { $0() }
        defer {
            barriers.forEach { $0.release() }
            endSnapshotTransaction()
        }
        for barrier in barriers {
            await barrier.waitUntilReached()
        }
        diagnosticLines.removeAll(keepingCapacity: true)
    }

    func makeExportURL() async throws -> URL {
        await beginSnapshotTransaction()
        let barriers = diagnosticsBarrierFactories.map { $0() }
        defer {
            barriers.forEach { $0.release() }
            endSnapshotTransaction()
        }
        for barrier in barriers {
            await barrier.waitUntilReached()
        }
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
            .appendingPathComponent(
                "SingleGreenDemo-logs-\(formatter.string(from: Date()))-\(UUID().uuidString).txt"
            )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func beginSnapshotTransaction() async {
        guard snapshotTransactionActive else {
            snapshotTransactionActive = true
            return
        }
        await withCheckedContinuation { continuation in
            snapshotTransactionWaiters.append(continuation)
        }
    }

    private func endSnapshotTransaction() {
        guard !snapshotTransactionWaiters.isEmpty else {
            snapshotTransactionActive = false
            return
        }
        snapshotTransactionWaiters.removeFirst().resume()
    }
}

enum DiagnosticsExportError: Error {
    case unavailable
}
#endif
