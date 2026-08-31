#if INTERNAL_DIAGNOSTICS
import Foundation
import SingleGreenGlassesKit
import VoiceChatCore
import XCTest
@testable import SingleGreenDemo

@MainActor
final class VoiceActivatedDiagnosticsTests: XCTestCase {
    func testRelaysEventsUnchangedAndRecordsOnlySparseMilestones() async throws {
        let base = DiagnosticsFakeVoiceActivatedSession()
        let writer = RecordingVADDiagnosticsWriter()
        let clock = DiagnosticsManualClock()
        let session = makeSession(base: base, writer: writer, clock: clock, runOrdinal: 7)
        let secretTranscript = "SENSITIVE_TRANSCRIPT_PAYLOAD"
        let secretUtterance = "SENSITIVE_UTTERANCE_PAYLOAD"
        let expected: [VoiceActivatedRecognitionEvent] = [
            .phase(.armed),
            .transcript(secretTranscript),
            .level(0.73),
            .phase(.speechStarted),
            .utterance(secretUtterance),
            .phase(.finalizing(.silence)),
            .finished
        ]
        let collector = collect(session.events)

        clock.set(milliseconds: 10)
        await base.emit(.phase(.armed))
        await waitForRecordCount(2, writer: writer)
        clock.set(milliseconds: 20)
        await base.emit(.transcript(secretTranscript))
        await base.emit(.level(0.73))
        clock.set(milliseconds: 30)
        await base.emit(.phase(.speechStarted))
        await waitForRecordCount(3, writer: writer)
        clock.set(milliseconds: 40)
        await base.emit(.utterance(secretUtterance))
        clock.set(milliseconds: 130)
        await base.emit(.phase(.finalizing(.silence)))
        await waitForRecordCount(4, writer: writer)
        clock.set(milliseconds: 160)
        await base.emit(.finished)
        await base.close()

        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, expected)
        await waitForRecordCount(5, writer: writer)
        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .armed,
            .speechStarted(armedToOnset: .milliseconds(20)),
            .finalizing(.silence, speechToEndpoint: .milliseconds(100)),
            .finished(endpointToFinished: .milliseconds(30))
        ])
        XCTAssertTrue(writer.records.allSatisfy { $0.runOrdinal == 7 })

        let export = writer.records.map(\.exportLine).joined(separator: "\n")
        XCTAssertFalse(export.contains(secretTranscript))
        XCTAssertFalse(export.contains(secretUtterance))
        XCTAssertFalse(export.contains("transcript"))
        XCTAssertFalse(export.contains("utterance"))
        XCTAssertFalse(export.contains("level="))
    }

    func testRecordsAllEndpointReasonsWithExplicitIntervals() async {
        let cases: [(VoiceEndpointReason, String)] = [
            (.silence, "silence"),
            (.maximumDuration, "maximum_duration"),
            (.manual, "manual")
        ]

        for (index, item) in cases.enumerated() {
            let base = DiagnosticsFakeVoiceActivatedSession()
            let writer = RecordingVADDiagnosticsWriter()
            let clock = DiagnosticsManualClock()
            let session = makeSession(
                base: base,
                writer: writer,
                clock: clock,
                runOrdinal: UInt64(index + 1)
            )
            let collector = collect(session.events)

            clock.set(milliseconds: 5)
            await base.emit(.phase(.armed))
            await waitForRecordCount(2, writer: writer)
            clock.set(milliseconds: 25)
            await base.emit(.phase(.speechStarted))
            await waitForRecordCount(3, writer: writer)
            clock.set(milliseconds: 225)
            await base.emit(.phase(.finalizing(item.0)))
            await waitForRecordCount(4, writer: writer)
            clock.set(milliseconds: 275)
            await base.emit(.finished)
            await base.close()

            _ = await collector.value
            await waitForRecordCount(5, writer: writer)
            let lines = writer.records.map(\.exportLine)
            XCTAssertTrue(lines.contains {
                $0.contains("event=speech_started") && $0.contains("armed_to_onset_ms=20")
            })
            XCTAssertTrue(lines.contains {
                $0.contains("event=finalizing")
                    && $0.contains("endpoint=\(item.1)")
                    && $0.contains("speech_to_endpoint_ms=200")
            })
            XCTAssertTrue(lines.contains {
                $0.contains("event=finished") && $0.contains("endpoint_to_finished_ms=50")
            })
        }
    }

    func testForwardsOperationsOnceAndRecordsMonotonicDurations() async throws {
        let clock = DiagnosticsManualClock()
        let base = DiagnosticsFakeVoiceActivatedSession(
            onArm: { clock.advance(milliseconds: 25) },
            onFinish: { clock.advance(milliseconds: 7) },
            onCancel: { clock.advance(milliseconds: 3) }
        )
        let writer = RecordingVADDiagnosticsWriter()
        let session = makeSession(base: base, writer: writer, clock: clock, runOrdinal: 12)
        let collector = collect(session.events)

        clock.set(milliseconds: 10)
        try await session.arm()
        clock.set(milliseconds: 50)
        await session.finish()
        clock.set(milliseconds: 70)
        async let firstCancel: Void = session.cancel()
        async let secondCancel: Void = session.cancel()
        _ = await (firstCancel, secondCancel)
        await base.close()

        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, [])
        await waitForRecordCount(8, writer: writer)
        let counts = await base.operationCounts
        XCTAssertEqual(counts.arm, 1)
        XCTAssertEqual(counts.finish, 1)
        XCTAssertEqual(counts.cancel, 1)
        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .armRequested,
            .armReturned(durationMilliseconds: 25),
            .finishRequested,
            .finishReturned(durationMilliseconds: 7),
            .cancelRequested,
            .cancelReturned(durationMilliseconds: 3),
            .sourceClosedWithoutTerminal(cancelRequested: true)
        ])
    }

    func testNoSpeechIsTerminalWithoutSyntheticFinished() async {
        let base = DiagnosticsFakeVoiceActivatedSession()
        let writer = RecordingVADDiagnosticsWriter()
        let session = makeSession(base: base, writer: writer)
        let collector = collect(session.events)

        await base.emit(.noSpeech)
        await base.emit(.noSpeech)
        await base.close()

        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, [.noSpeech, .noSpeech])
        await waitForRecordCount(2, writer: writer)
        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .noSpeech
        ])
    }

    func testFailureRecordsOnlyTypedCodeAndDeduplicatesTerminalDiagnostics() async {
        let base = DiagnosticsFakeVoiceActivatedSession()
        let writer = RecordingVADDiagnosticsWriter()
        let session = makeSession(base: base, writer: writer)
        let collector = collect(session.events)
        let sensitivePayload = "SENSITIVE_PROVIDER_FAILURE_PAYLOAD"
        let failure = SpeechRecognitionFailure(
            code: .connectionLost,
            userSafeMessage: sensitivePayload
        )

        await base.emit(.failed(failure))
        await base.emit(.finished)
        await base.close()

        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, [.failed(failure), .finished])
        await waitForRecordCount(2, writer: writer)
        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .failed(.connectionLost)
        ])
        XCTAssertFalse(writer.records.map(\.exportLine).joined().contains(sensitivePayload))
    }

    func testArmFailureUsesTypedCodeWithoutPersistingErrorPayload() async {
        let sensitivePayload = "SENSITIVE_ARM_ERROR_PAYLOAD"
        let base = DiagnosticsFakeVoiceActivatedSession(
            armError: DiagnosticsSensitiveError(message: sensitivePayload)
        )
        let writer = RecordingVADDiagnosticsWriter()
        let clock = DiagnosticsManualClock()
        let session = makeSession(base: base, writer: writer, clock: clock)

        clock.set(milliseconds: 10)
        do {
            try await session.arm()
            XCTFail("Expected arm to fail")
        } catch {
            XCTAssertEqual((error as? DiagnosticsSensitiveError)?.message, sensitivePayload)
        }

        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .armRequested,
            .armFailed(durationMilliseconds: 0, code: .unknown)
        ])
        XCTAssertFalse(writer.records.map(\.exportLine).joined().contains(sensitivePayload))
    }

    func testSourceCloseWithoutTerminalRecordsCancellationStateWithoutSynthesizingEvent() async {
        let base = DiagnosticsFakeVoiceActivatedSession()
        let writer = RecordingVADDiagnosticsWriter()
        let session = makeSession(base: base, writer: writer)
        let collector = collect(session.events)

        await base.close()

        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, [])
        await waitForRecordCount(2, writer: writer)
        XCTAssertEqual(writer.records.map(\.milestone), [
            .configured(productionSnapshot),
            .sourceClosedWithoutTerminal(cancelRequested: false)
        ])
    }

    func testCancelRequestedBeforeSourceCloseIsRecordedDeterministically() async {
        let cancelGate = DiagnosticsCancelGate()
        let base = DiagnosticsFakeVoiceActivatedSession(
            onCancel: { await cancelGate.wait() }
        )
        let writer = RecordingVADDiagnosticsWriter()
        let session = makeSession(base: base, writer: writer)
        let collector = collect(session.events)

        let cancelTask = Task { await session.cancel() }
        await cancelGate.waitUntilStarted()
        await base.close()
        let collectedEvents = await collector.value
        XCTAssertEqual(collectedEvents, [])
        await waitForRecordCount(3, writer: writer)
        await cancelGate.release()
        await cancelTask.value

        XCTAssertTrue(writer.records.contains {
            $0.milestone == .sourceClosedWithoutTerminal(cancelRequested: true)
        })
        XCTAssertFalse(writer.records.contains {
            $0.milestone == .sourceClosedWithoutTerminal(cancelRequested: false)
        })
    }

    func testPolicySnapshotAndSchemaContainOnlyApprovedFields() {
        let record = InternalVADDiagnosticRecord(
            runOrdinal: 3,
            elapsedMilliseconds: 9,
            milestone: .configured(productionSnapshot)
        )
        let line = record.exportLine

        XCTAssertTrue(line.hasPrefix("schema=v2 run=3 event=configured elapsed_ms=9 "))
        XCTAssertTrue(line.contains("aggressiveness_mode=2"))
        XCTAssertTrue(line.contains("endpoint_silence_frames=40"))
        XCTAssertTrue(line.contains("maximum_segment_frames=1000"))
        XCTAssertTrue(line.contains("no_speech_frames=750"))
        for forbidden in ["api", "key", "resource", "prompt", "device", "route", "provider"] {
            XCTAssertFalse(line.lowercased().contains(forbidden))
        }
    }

    func testCoreProgressIsCadencedStaleIsRejectedAndExportUsesAllowlistedFields() {
        let writer = RecordingVADDiagnosticsWriter()
        let clock = DiagnosticsManualClock()
        let context = InternalVADRunContext(core: VoiceActivatedASRDiagnosticContext(
            runOrdinal: 41,
            originNanoseconds: 0
        ))
        let recorder = InternalVADCoreDiagnosticsRecorder(
            context: context,
            writer: writer,
            monotonicNow: clock.now
        )

        recorder.observe(.sourceStartRequested(generation: 3))
        for accepted in 1...26 {
            recorder.observe(.progress(
                generation: 3,
                trigger: .frameAccepted,
                progress: diagnosticProgress(accepted: accepted, processed: 0)
            ))
        }
        recorder.observe(.progress(
            generation: 2,
            trigger: .detectorProcessed,
            progress: diagnosticProgress(accepted: 99, processed: 99)
        ))
        clock.set(milliseconds: 500)
        recorder.observe(.progress(
            generation: 3,
            trigger: .detectorProcessed,
            progress: diagnosticProgress(accepted: 27, processed: 1)
        ))

        let progressRecords = writer.records.filter {
            if case .core(.progress) = $0.milestone { return true }
            return false
        }
        XCTAssertEqual(progressRecords.count, 3)
        let export = writer.records.map(\.exportLine).joined(separator: "\n")
        XCTAssertTrue(export.contains("schema=v2 run=41 event=core_progress"))
        XCTAssertTrue(export.contains("accepted_frames=26 processed_frames=0"))
        XCTAssertTrue(export.contains("accepted_frames=27 processed_frames=1"))
        XCTAssertFalse(export.contains("accepted_frames=99"))
        for forbidden in ["pcm", "transcript", "utterance", "level=", "credential", "route", "device"] {
            XCTAssertFalse(export.lowercased().contains(forbidden))
        }
    }

    func testSerialWriterIsBoundedAndPreservesRetainedOrder() async {
        let sink = BlockingVADLineSink()
        let writer = InternalVADDiagnosticsSerialWriter(capacity: 2) { line in
            await sink.write(line)
        }

        writer.submit(record(elapsedMilliseconds: 0))
        await sink.waitUntilFirstWriteStarts()
        writer.submit(record(elapsedMilliseconds: 1))
        writer.submit(record(elapsedMilliseconds: 2))
        writer.submit(record(elapsedMilliseconds: 3))
        await sink.releaseFirstWrite()
        await sink.waitForCount(3)

        let lines = await sink.lines
        XCTAssertEqual(lines.compactMap(elapsedMilliseconds(from:)), [0, 2, 3])
    }

    func testWriterCloseIdempotentlyReachesAndReleasesQueuedBarrier() async {
        let sink = BlockingVADLineSink()
        var writer: InternalVADDiagnosticsSerialWriter? = InternalVADDiagnosticsSerialWriter(
            capacity: 2,
            sink: { line in await sink.write(line) }
        )
        writer?.submit(record(elapsedMilliseconds: 8))
        await sink.waitUntilFirstWriteStarts()
        guard let barrier = writer?.makeBarrier() else {
            return XCTFail("Expected queued barrier")
        }

        writer = nil
        await barrier.waitUntilReached()
        barrier.release()
        barrier.release()
        await sink.releaseFirstWrite()

    }

    func testSerialWriterExportsTypedVADCategoryAndSchemaToStore() async {
        let store = ConversationTelemetryStore(capacity: 4)
        let writer = InternalVADDiagnosticsSerialWriter(capacity: 4) { line in
            await store.record(category: "vad", message: line)
        }

        writer.submit(record(elapsedMilliseconds: 4))
        for _ in 0..<1_000 where store.diagnosticLines.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(store.diagnosticLines.count, 1)
        XCTAssertTrue(store.diagnosticLines[0].contains("[vad] schema=v2 run=1"))
    }

    func testExportFlushIncludesQueuedTerminalAndClearDrainsPreClearRecords() async throws {
        let exportStore = ConversationTelemetryStore(capacity: 8)
        let exportSink = BlockingVADLineSink()
        let exportWriter = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await exportSink.write(line)
            await exportStore.record(category: "vad", message: line)
        }
        exportStore.registerDiagnosticsBarrierFactory { exportWriter.makeBarrier() }
        exportWriter.submit(record(elapsedMilliseconds: 1))
        await exportSink.waitUntilFirstWriteStarts()
        exportWriter.submit(InternalVADDiagnosticRecord(
            runOrdinal: 1,
            elapsedMilliseconds: 2,
            milestone: .finished(endpointToFinished: .milliseconds(4))
        ))
        let exportTask = Task { try await exportStore.makeExportURL() }

        XCTAssertTrue(exportStore.diagnosticLines.isEmpty)
        await exportSink.releaseFirstWrite()
        let exportURL = try await exportTask.value
        let exportContents = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exportContents.contains("event=finished"))
        XCTAssertTrue(exportContents.contains("endpoint_to_finished_ms=4"))

        let clearStore = ConversationTelemetryStore(capacity: 8)
        let clearSink = BlockingVADLineSink()
        let clearWriter = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await clearSink.write(line)
            await clearStore.record(category: "vad", message: line)
        }
        clearStore.registerDiagnosticsBarrierFactory { clearWriter.makeBarrier() }
        clearWriter.submit(record(elapsedMilliseconds: 10))
        await clearSink.waitUntilFirstWriteStarts()
        clearWriter.submit(record(elapsedMilliseconds: 11))
        let clearTask = Task { await clearStore.removeAllDiagnostics() }

        await clearSink.releaseFirstWrite()
        await clearTask.value
        let drainBarrier = clearWriter.makeBarrier()
        await drainBarrier.waitUntilReached()
        drainBarrier.release()
        XCTAssertTrue(clearStore.diagnosticLines.isEmpty)
    }

    func testTwoWriterExportUsesAtomicCutoffAndDeliversPostBarrierRecordAfterRelease() async throws {
        let store = ConversationTelemetryStore(capacity: 16)
        let writerA = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await store.record(category: "vad", message: line)
        }
        let blockedSinkB = BlockingVADLineSink()
        let writerB = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await blockedSinkB.write(line)
            await store.record(category: "vad", message: line)
        }
        let captureA = DiagnosticsBarrierCapture()
        let captureB = DiagnosticsBarrierCapture()
        store.registerDiagnosticsBarrierFactory {
            captureA.capture(writerA.makeBarrier())
        }
        store.registerDiagnosticsBarrierFactory {
            captureB.capture(writerB.makeBarrier())
        }

        writerA.submit(record(elapsedMilliseconds: 100))
        let initialDrainA = writerA.makeBarrier()
        await initialDrainA.waitUntilReached()
        initialDrainA.release()
        writerB.submit(record(elapsedMilliseconds: 101))
        await blockedSinkB.waitUntilFirstWriteStarts()

        let exportTask = Task { try await store.makeExportURL() }
        let transactionBarrierA = await captureA.next()
        _ = await captureB.next()
        await transactionBarrierA.waitUntilReached()
        writerA.submit(record(elapsedMilliseconds: 102))
        XCTAssertFalse(store.diagnosticLines.contains { $0.contains("elapsed_ms=102") })

        await blockedSinkB.releaseFirstWrite()
        let exportURL = try await exportTask.value
        let exportContents = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exportContents.contains("elapsed_ms=100"))
        XCTAssertTrue(exportContents.contains("elapsed_ms=101"))
        XCTAssertFalse(exportContents.contains("elapsed_ms=102"))

        let postBarrierDrainA = writerA.makeBarrier()
        await postBarrierDrainA.waitUntilReached()
        XCTAssertTrue(store.diagnosticLines.contains { $0.contains("elapsed_ms=102") })
        postBarrierDrainA.release()
    }

    func testTwoWriterClearPreservesPostBarrierRecordAndDoesNotDeadlock() async {
        let store = ConversationTelemetryStore(capacity: 16)
        let writerA = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await store.record(category: "vad", message: line)
        }
        let blockedSinkB = BlockingVADLineSink()
        let writerB = InternalVADDiagnosticsSerialWriter(capacity: 8) { line in
            await blockedSinkB.write(line)
            await store.record(category: "vad", message: line)
        }
        let captureA = DiagnosticsBarrierCapture()
        let captureB = DiagnosticsBarrierCapture()
        store.registerDiagnosticsBarrierFactory {
            captureA.capture(writerA.makeBarrier())
        }
        store.registerDiagnosticsBarrierFactory {
            captureB.capture(writerB.makeBarrier())
        }

        writerA.submit(record(elapsedMilliseconds: 200))
        let initialDrainA = writerA.makeBarrier()
        await initialDrainA.waitUntilReached()
        initialDrainA.release()
        writerB.submit(record(elapsedMilliseconds: 201))
        await blockedSinkB.waitUntilFirstWriteStarts()

        let clearTask = Task { await store.removeAllDiagnostics() }
        let transactionBarrierA = await captureA.next()
        _ = await captureB.next()
        await transactionBarrierA.waitUntilReached()
        writerA.submit(record(elapsedMilliseconds: 202))

        await blockedSinkB.releaseFirstWrite()
        await clearTask.value
        let postBarrierDrainA = writerA.makeBarrier()
        await postBarrierDrainA.waitUntilReached()
        let linesAfterClear = store.diagnosticLines
        postBarrierDrainA.release()

        XCTAssertFalse(linesAfterClear.contains { $0.contains("elapsed_ms=200") })
        XCTAssertFalse(linesAfterClear.contains { $0.contains("elapsed_ms=201") })
        XCTAssertTrue(linesAfterClear.contains { $0.contains("elapsed_ms=202") })
    }

    func testImmediateExportsUseUniqueURLsAndPreserveIndependentSnapshots() async throws {
        let store = ConversationTelemetryStore(capacity: 8)
        store.record(category: "test", message: "first-snapshot-marker")

        let firstURL = try await store.makeExportURL()
        let firstContents = try String(contentsOf: firstURL, encoding: .utf8)
        store.record(category: "test", message: "second-snapshot-marker")
        let secondURL = try await store.makeExportURL()
        let secondContents = try String(contentsOf: secondURL, encoding: .utf8)

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertTrue(firstContents.contains("first-snapshot-marker"))
        XCTAssertFalse(firstContents.contains("second-snapshot-marker"))
        XCTAssertTrue(secondContents.contains("first-snapshot-marker"))
        XCTAssertTrue(secondContents.contains("second-snapshot-marker"))
    }

    func testLiveCompositionDecoratesSessionExportsSchemaAndUsesProcessOrdinals() async throws {
        let storeA = ConversationTelemetryStore(capacity: 8)
        let storeB = ConversationTelemetryStore(capacity: 8)
        let baseA = DiagnosticsFakeVoiceActivatedSession()
        let baseB = DiagnosticsFakeVoiceActivatedSession()
        let wiringA = InternalVADDiagnosticsLiveComposition.make(
            diagnosticSink: storeA,
            monotonicNow: { 0 },
            makeAdaptedSession: { _ in baseA }
        )
        let wiringB = InternalVADDiagnosticsLiveComposition.make(
            diagnosticSink: storeB,
            monotonicNow: { 0 },
            makeAdaptedSession: { _ in baseB }
        )

        XCTAssertEqual(
            wiringA.marker,
            "vad-diagnostics-live-wiring-v2"
        )
        let sessionA = try wiringA.makeVoiceActivatedSession(speechConfiguration)
        let sessionB = try wiringB.makeVoiceActivatedSession(speechConfiguration)
        XCTAssertTrue(sessionA is InternalVoiceActivatedDiagnosticsSession)
        XCTAssertTrue(sessionB is InternalVoiceActivatedDiagnosticsSession)
        let exportA = try await storeA.makeExportURL()
        let contentsA = try String(contentsOf: exportA, encoding: .utf8)
        let exportB = try await storeB.makeExportURL()
        let contentsB = try String(contentsOf: exportB, encoding: .utf8)

        XCTAssertTrue(contentsA.contains("[vad] schema=v2"))
        XCTAssertTrue(contentsB.contains("[vad] schema=v2"))
        let ordinalA = configuredRunOrdinal(from: contentsA)
        let ordinalB = configuredRunOrdinal(from: contentsB)
        XCTAssertNotNil(ordinalA)
        XCTAssertNotNil(ordinalB)
        XCTAssertNotEqual(ordinalA, ordinalB)
        await sessionA.cancel()
        await sessionB.cancel()
    }

    func testActualLiveDependenciesReturnDecoratedVoiceSessionAndExportSchema() async throws {
        let settings = AISettings(
            buildPolicy: .serverManaged,
            speechInputAvailability: .productionDetectorAvailable
        )
        let originalResourceID = settings.asrResourceID
        defer { settings.asrResourceID = originalResourceID }
        settings.asrResourceID = "fixture-resource"
        let store = ConversationTelemetryStore(capacity: 8)
        let dependencies = VoiceConversationDependencies.live(
            settings: settings,
            credentialProvider: DiagnosticsCredentialProvider(),
            telemetry: store
        )

        let prepared = try await dependencies.prepareSpeechInput(.voiceActivated)
        guard case .voiceActivated(let session) = prepared else {
            return XCTFail("Expected voice-activated live preparation")
        }
        XCTAssertTrue(session is InternalVoiceActivatedDiagnosticsSession)
        await session.cancel()
        let url = try await store.makeExportURL()
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(contents.contains("[vad] schema=v2"))
        XCTAssertFalse(contents.contains(DiagnosticsCredentialProvider.sensitiveCredential))
    }

    private var productionSnapshot: InternalVADPolicySnapshot {
        InternalVADPolicySnapshot(
            policy: ProductionVoiceActivatedSessionFactory.policy,
            aggressiveness: ProductionVoiceActivatedSessionFactory.aggressiveness
        )
    }

    private var speechConfiguration: SpeechProviderConfiguration {
        SpeechProviderConfiguration(
            apiKey: "fixture-speech-credential",
            resourceID: "fixture-resource",
            language: "zh-CN",
            hotwords: []
        )
    }

    private func makeSession(
        base: DiagnosticsFakeVoiceActivatedSession,
        writer: RecordingVADDiagnosticsWriter,
        clock: DiagnosticsManualClock = DiagnosticsManualClock(),
        runOrdinal: UInt64 = 1
    ) -> InternalVoiceActivatedDiagnosticsSession {
        InternalVoiceActivatedDiagnosticsSession(
            base: base,
            policySnapshot: productionSnapshot,
            runOrdinal: runOrdinal,
            writer: writer,
            monotonicNow: clock.now
        )
    }

    private func collect(
        _ stream: AsyncStream<VoiceActivatedRecognitionEvent>
    ) -> Task<[VoiceActivatedRecognitionEvent], Never> {
        Task {
            var events: [VoiceActivatedRecognitionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
    }

    private func waitForRecordCount(
        _ count: Int,
        writer: RecordingVADDiagnosticsWriter
    ) async {
        for _ in 0..<1_000 {
            if writer.records.count >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(count) diagnostic records")
    }

    private func record(elapsedMilliseconds: UInt64) -> InternalVADDiagnosticRecord {
        InternalVADDiagnosticRecord(
            runOrdinal: 1,
            elapsedMilliseconds: elapsedMilliseconds,
            milestone: .armRequested
        )
    }

    private func diagnosticProgress(
        accepted: Int,
        processed: Int
    ) -> VoiceActivatedASRDiagnosticProgress {
        VoiceActivatedASRDiagnosticProgress(
            acceptedFrameCount: accepted,
            processedFrameCount: processed,
            speechFrameCount: processed,
            silenceFrameCount: 0,
            currentSilenceStreak: 0,
            maximumSilenceStreak: 0,
            pendingFrameCount: accepted - processed
        )
    }

    private func elapsedMilliseconds(from line: String) -> UInt64? {
        line.split(separator: " ")
            .first { $0.hasPrefix("elapsed_ms=") }
            .flatMap { UInt64($0.dropFirst("elapsed_ms=".count)) }
    }

    private func configuredRunOrdinal(from contents: String) -> UInt64? {
        contents.split(separator: "\n")
            .first { $0.contains("event=configured") }
            .flatMap { line in
                line.split(separator: " ")
                    .first { $0.hasPrefix("run=") }
                    .flatMap { UInt64($0.dropFirst("run=".count)) }
            }
    }
}

private final class DiagnosticsManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 0

    func now() -> UInt64 {
        lock.withLock { nanoseconds }
    }

    func set(milliseconds: UInt64) {
        lock.withLock { nanoseconds = milliseconds * 1_000_000 }
    }

    func advance(milliseconds: UInt64) {
        lock.withLock { nanoseconds += milliseconds * 1_000_000 }
    }
}

private final class RecordingVADDiagnosticsWriter:
    InternalVADDiagnosticsWriting,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InternalVADDiagnosticRecord] = []

    var records: [InternalVADDiagnosticRecord] {
        lock.withLock { storage }
    }

    func submit(_ record: InternalVADDiagnosticRecord) {
        lock.withLock { storage.append(record) }
    }

    func flush() async {}
}

private actor DiagnosticsFakeVoiceActivatedSession: VoiceActivatedSpeechRecognitionSession {
    nonisolated let events: AsyncStream<VoiceActivatedRecognitionEvent>

    private let continuation: AsyncStream<VoiceActivatedRecognitionEvent>.Continuation
    private let armError: (any Error)?
    private let onArm: @Sendable () async -> Void
    private let onFinish: @Sendable () async -> Void
    private let onCancel: @Sendable () async -> Void
    private var armCount = 0
    private var finishCount = 0
    private var cancelCount = 0

    init(
        armError: (any Error)? = nil,
        onArm: @escaping @Sendable () async -> Void = {},
        onFinish: @escaping @Sendable () async -> Void = {},
        onCancel: @escaping @Sendable () async -> Void = {}
    ) {
        let (events, continuation) = AsyncStream<VoiceActivatedRecognitionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.armError = armError
        self.onArm = onArm
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var operationCounts: (arm: Int, finish: Int, cancel: Int) {
        (armCount, finishCount, cancelCount)
    }

    func arm() async throws {
        armCount += 1
        await onArm()
        if let armError { throw armError }
    }

    func finish() async {
        finishCount += 1
        await onFinish()
    }

    func cancel() async {
        cancelCount += 1
        await onCancel()
    }

    func emit(_ event: VoiceActivatedRecognitionEvent) {
        continuation.yield(event)
    }

    func close() {
        continuation.finish()
    }
}

private struct DiagnosticsSensitiveError: Error, Sendable {
    let message: String
}

private struct DiagnosticsCredentialProvider: ConversationCredentialProvider {
    static let sensitiveCredential = "SENSITIVE_LIVE_SPEECH_CREDENTIAL"

    func lease() async throws -> ConversationCredentialLease {
        ConversationCredentialLease(
            speechAPIKey: Self.sensitiveCredential,
            llmAPIKey: "",
            searchAPIKey: "",
            agentAccountScope: .init(opaqueID: "diagnostics-fixture-account"),
            expiresAt: .distantFuture
        )
    }
}

private actor DiagnosticsCancelGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class DiagnosticsBarrierCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [InternalDiagnosticsBarrierHandle] = []
    private var waiters: [CheckedContinuation<InternalDiagnosticsBarrierHandle, Never>] = []

    func capture(
        _ handle: InternalDiagnosticsBarrierHandle
    ) -> InternalDiagnosticsBarrierHandle {
        let waiter: CheckedContinuation<InternalDiagnosticsBarrierHandle, Never>? = lock.withLock {
            guard !waiters.isEmpty else {
                handles.append(handle)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: handle)
        return handle
    }

    func next() async -> InternalDiagnosticsBarrierHandle {
        await withCheckedContinuation { continuation in
            let handle: InternalDiagnosticsBarrierHandle? = lock.withLock {
                guard !handles.isEmpty else {
                    waiters.append(continuation)
                    return nil
                }
                return handles.removeFirst()
            }
            if let handle { continuation.resume(returning: handle) }
        }
    }
}

private actor BlockingVADLineSink {
    private(set) var lines: [String] = []
    private var firstWriteStarted = false
    private var firstWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstWriteRelease: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func write(_ line: String) async {
        lines.append(line)
        resumeCountWaiters()
        guard !firstWriteStarted else { return }
        firstWriteStarted = true
        firstWriteWaiters.forEach { $0.resume() }
        firstWriteWaiters.removeAll()
        await withCheckedContinuation { continuation in
            firstWriteRelease = continuation
        }
    }

    func waitUntilFirstWriteStarts() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { continuation in
            firstWriteWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        firstWriteRelease?.resume()
        firstWriteRelease = nil
    }

    func waitForCount(_ count: Int) async {
        guard lines.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    private func resumeCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if lines.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }
}
#endif
