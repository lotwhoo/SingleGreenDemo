#if INTERNAL_DIAGNOSTICS
import Foundation
import SingleGreenGlassesKit
import XCTest
@testable import SingleGreenDemo

@MainActor
final class TeleprompterASRDiagnosticsTests: XCTestCase {
    func testCompositionRecordsConsentPermissionAndTypedPreparationGatesWithoutPayloads() async {
        let sink = TeleprompterDiagnosticsSink()
        let sensitivePayload = "SENSITIVE_PREPARATION_PAYLOAD"
        let base = TeleprompterDependencies(
            prepareSpeechSession: {
                throw ConversationPreparationFailure(
                    userSafeMessage: sensitivePayload,
                    failureCode: .configurationMissing
                )
            },
            requestMicrophonePermission: { false },
            cloudSpeechRecognitionAllowed: { false }
        )
        let wiring = InternalTeleprompterASRDiagnosticsLiveComposition.make(
            diagnosticSink: sink,
            base: base
        )
        XCTAssertEqual(wiring.marker, "teleprompter-asr-diagnostics-live-wiring-v1")
        XCTAssertFalse(wiring.dependencies.cloudSpeechRecognitionAllowed())
        let microphonePermissionGranted = await wiring.dependencies.requestMicrophonePermission()
        XCTAssertFalse(microphonePermissionGranted)
        do {
            _ = try await wiring.dependencies.prepareSpeechSession()
            XCTFail("Expected preparation failure")
        } catch {
            XCTAssertEqual(
                (error as? ConversationPreparationFailure)?.failureCode,
                .configurationMissing
            )
        }
        await sink.drain()

        let lines = sink.lines
        XCTAssertTrue(lines.allSatisfy { $0.category == "teleprompter_asr" })
        XCTAssertTrue(lines.contains { $0.line.contains("event=consent_checked allowed=false") })
        XCTAssertTrue(lines.contains { $0.line.contains("event=permission_requested") })
        XCTAssertTrue(lines.contains { $0.line.contains("event=permission_returned allowed=false") })
        XCTAssertTrue(lines.contains { $0.line.contains("event=preparation_requested") })
        XCTAssertTrue(lines.contains {
            $0.line.contains("event=preparation_failed failure=configurationMissing")
        })
        XCTAssertFalse(lines.map(\.line).joined().contains(sensitivePayload))
    }

    func testSessionRelaysEveryEventInOrderAndRedactsContentAndLevels() async throws {
        let collector = TeleprompterDiagnosticsLineCollector()
        let writer = InternalDiagnosticsOrderedLineWriter { line in
            await collector.append(category: "teleprompter_asr", line: line)
        }
        let recorder = InternalTeleprompterASRDiagnosticsRecorder(writer: writer)
        let base = TeleprompterDiagnosticsFakeSession()
        let session = InternalTeleprompterASRDiagnosticsSession(
            base: base,
            runOrdinal: 9,
            recorder: recorder
        )
        let sensitiveTranscript = "SENSITIVE_TRANSCRIPT_PAYLOAD"
        let sensitiveUtterance = "SENSITIVE_UTTERANCE_PAYLOAD"
        let failure = SpeechRecognitionFailure(
            code: .connectionLost,
            userSafeMessage: "SENSITIVE_FAILURE_PAYLOAD"
        )
        let expected: [SpeechRecognitionEvent] = [
            .level(0.42),
            .level(0.91),
            .transcript(sensitiveTranscript),
            .utterance(sensitiveUtterance),
            .failed(failure),
            .finished
        ]
        let collectedEvents = collect(session.events)

        try await session.start()
        for event in expected { base.emit(event) }
        base.close()
        let relayed = await collectedEvents.value
        await drain(writer)

        XCTAssertEqual(relayed, expected)
        XCTAssertEqual(base.startCount, 1)
        let export = (await collector.lines).map(\.line).joined(separator: "\n")
        XCTAssertTrue(export.contains("run=9 event=start_requested"))
        XCTAssertTrue(export.contains("run=9 event=start_returned"))
        XCTAssertEqual(export.components(separatedBy: "event=first_level_observed").count - 1, 1)
        XCTAssertTrue(export.contains("event=transcript_observed sequence=1"))
        XCTAssertTrue(export.contains("event=utterance_observed sequence=2"))
        XCTAssertEqual(export.components(separatedBy: "event=failed").count - 1, 1)
        for forbidden in [sensitiveTranscript, sensitiveUtterance, "SENSITIVE_FAILURE_PAYLOAD", "0.42", "0.91"] {
            XCTAssertFalse(export.contains(forbidden))
        }
    }

    func testSessionLifecycleDelegatesOnceAndSourceCloseRecordsCancellationState() async {
        let collector = TeleprompterDiagnosticsLineCollector()
        let writer = InternalDiagnosticsOrderedLineWriter { line in
            await collector.append(category: "teleprompter_asr", line: line)
        }
        let recorder = InternalTeleprompterASRDiagnosticsRecorder(writer: writer)
        let base = TeleprompterDiagnosticsFakeSession()
        let session = InternalTeleprompterASRDiagnosticsSession(
            base: base,
            runOrdinal: 3,
            recorder: recorder
        )
        let collectedEvents = collect(session.events)

        await session.finish()
        await session.cancel()
        base.close()
        let relayedEvents = await collectedEvents.value
        XCTAssertEqual(relayedEvents, [])
        await drain(writer)

        XCTAssertEqual(base.finishCount, 1)
        XCTAssertEqual(base.cancelCount, 1)
        let export = (await collector.lines).map(\.line).joined(separator: "\n")
        for event in ["finish_requested", "finish_returned", "cancel_requested", "cancel_returned"] {
            XCTAssertEqual(export.components(separatedBy: "event=\(event)").count - 1, 1)
        }
        XCTAssertTrue(export.contains(
            "event=source_closed_without_terminal cancel_requested=true"
        ))
    }

    func testStateObserverSeparatesASRDeliveryFromAlignmentAndNeverLogsScript() async throws {
        let collector = TeleprompterDiagnosticsLineCollector()
        let writer = InternalDiagnosticsOrderedLineWriter { line in
            await collector.append(category: "teleprompter_asr", line: line)
        }
        let recorder = InternalTeleprompterASRDiagnosticsRecorder(writer: writer)
        let base = TeleprompterDiagnosticsFakeSession()
        let sensitiveScript = "第一句从这里开始。第二句现在开始。"
        let controller = TeleprompterController(
            script: try TeleprompterScript(sensitiveScript),
            dependencies: .init(
                prepareSpeechSession: { base },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )
        let observer = InternalTeleprompterStateDiagnosticsObserver(
            controller: controller,
            recorder: recorder
        )

        await controller.toggleFollowing()
        base.emit(.transcript("第一句从这里"))
        await settle()
        base.emit(.utterance("第一句从这里开始"))
        await settle()
        await drain(writer)
        withExtendedLifetime(observer) {}

        let export = (await collector.lines).map(\.line).joined(separator: "\n")
        XCTAssertTrue(export.contains("event=phase_changed phase=ready"))
        XCTAssertTrue(export.contains("event=phase_changed phase=listening"))
        XCTAssertTrue(export.contains("event=alignment_progressed"))
        XCTAssertTrue(export.contains("event=sentence_advanced sequence=1"))
        XCTAssertFalse(export.contains(sensitiveScript))
        XCTAssertFalse(export.contains("sentenceIndex"))
        XCTAssertFalse(export.contains("offset"))
    }

    func testLiveWiringDecoratesPreparedSessionAndExportFlushesCategory() async throws {
        let store = ConversationTelemetryStore(capacity: 32)
        let baseSession = TeleprompterDiagnosticsFakeSession()
        let sensitiveResource = "SENSITIVE_RESOURCE_IDENTIFIER"
        let wiring = InternalTeleprompterASRDiagnosticsLiveComposition.make(
            diagnosticSink: store,
            base: TeleprompterDependencies(
                prepareSpeechSession: { baseSession },
                requestMicrophonePermission: { true },
                cloudSpeechRecognitionAllowed: { true }
            )
        )

        XCTAssertTrue(wiring.dependencies.cloudSpeechRecognitionAllowed())
        let microphonePermissionGranted = await wiring.dependencies.requestMicrophonePermission()
        XCTAssertTrue(microphonePermissionGranted)
        let session = try await wiring.dependencies.prepareSpeechSession()
        XCTAssertTrue(session is InternalTeleprompterASRDiagnosticsSession)
        try await session.start()
        baseSession.emit(.transcript(sensitiveResource))
        baseSession.emit(.finished)
        baseSession.close()
        await settle()

        let url = try await store.makeExportURL()
        let export = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(export.contains("[teleprompter_asr] schema=v1"))
        XCTAssertTrue(export.contains("event=transcript_observed sequence=1"))
        XCTAssertTrue(export.contains("event=finished"))
        XCTAssertFalse(export.contains(sensitiveResource))
    }

    private func collect(
        _ stream: AsyncStream<SpeechRecognitionEvent>
    ) -> Task<[SpeechRecognitionEvent], Never> {
        Task {
            var events: [SpeechRecognitionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
    }

    private func drain(_ writer: InternalDiagnosticsOrderedLineWriter) async {
        let barrier = writer.makeBarrier()
        await barrier.waitUntilReached()
        barrier.release()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private actor TeleprompterDiagnosticsLineCollector {
    private(set) var lines: [TeleprompterDiagnosticsLineEntry] = []

    func append(category: String, line: String) {
        lines.append(.init(category: category, line: line))
    }
}

private struct TeleprompterDiagnosticsLineEntry: Sendable {
    let category: String
    let line: String
}

@MainActor
private final class TeleprompterDiagnosticsSink: InternalDiagnosticsLineSink {
    private(set) var lines: [TeleprompterDiagnosticsLineEntry] = []
    private var barrierFactories: [@Sendable () -> InternalDiagnosticsBarrierHandle] = []

    func record(category: String, message: String) {
        lines.append(.init(category: category, line: message))
    }

    func registerDiagnosticsBarrierFactory(
        _ factory: @escaping @Sendable () -> InternalDiagnosticsBarrierHandle
    ) {
        barrierFactories.append(factory)
    }

    func drain() async {
        let barriers = barrierFactories.map { $0() }
        for barrier in barriers { await barrier.waitUntilReached() }
        barriers.forEach { $0.release() }
    }
}

@MainActor
private final class TeleprompterDiagnosticsFakeSession: SpeechRecognitionSession {
    nonisolated let events: AsyncStream<SpeechRecognitionEvent>
    private let continuation: AsyncStream<SpeechRecognitionEvent>.Continuation
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    var startError: Error?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func emit(_ event: SpeechRecognitionEvent) { continuation.yield(event) }
    func close() { continuation.finish() }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func finish() async { finishCount += 1 }
    func cancel() async { cancelCount += 1 }
}
#endif
