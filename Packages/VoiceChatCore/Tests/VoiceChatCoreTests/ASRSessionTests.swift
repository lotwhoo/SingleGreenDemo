import XCTest
@testable import VoiceChatCore

final class ASRSessionTests: XCTestCase {

    func testConfigDefaults() {
        let config = ASRSession.Config(apiKey: "test-key")
        XCTAssertEqual(config.resourceID, "volc.seedasr.sauc.duration")
        XCTAssertEqual(config.host, "openspeech.bytedance.com")
        XCTAssertEqual(config.path, "/api/v3/sauc/bigmodel")
        XCTAssertEqual(config.language, "zh-CN")
        XCTAssertTrue(config.enableITN)
        XCTAssertTrue(config.enablePunc)
        XCTAssertTrue(config.showUtterances)
        XCTAssertTrue(config.hotwords.isEmpty)
        XCTAssertEqual(config.timeoutInterval, 30)
    }

    func testInitialState() {
        let session = ASRSession(config: .init(apiKey: "test"))
        XCTAssertEqual(session.state, .idle)
    }

    func testFinishInIdleIsNoOp() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        await session.finish()
        XCTAssertEqual(session.state, .idle)
    }

    func testCancelInIdleReturnsToIdle() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        await session.cancel()
        XCTAssertEqual(session.state, .idle)
    }

    func testEventsStreamSubscribable() {
        // 事件流应可正常订阅（不崩溃、可取消）
        let session = ASRSession(config: .init(apiKey: "test"))
        let task = Task {
            var count = 0
            for await _ in session.events { count += 1 }
            return count
        }
        task.cancel()
    }

    func testStateReadIsThreadSafe() async {
        let session = ASRSession(config: .init(apiKey: "test"))
        let reads = (0..<50).map { _ in
            Task { _ = session.state }
        }
        for t in reads { _ = await t.value }
        XCTAssertEqual(session.state, .idle)
    }

    func testConcurrentStartsAreSerializedAndSecondStartIsRejected() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)

        let firstStart = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        let secondStart = Task { () -> ASRSession.SessionError? in
            do {
                try await session.startStream()
                return nil
            } catch let error as ASRSession.SessionError {
                return error
            } catch {
                return nil
            }
        }

        await client.releaseStart()
        do {
            try await firstStart.value
        } catch {
            XCTFail("Unexpected first start failure: \(error)")
        }
        let secondError = await secondStart.value

        XCTAssertEqual(secondError, .busy)
        XCTAssertEqual(session.state, .recording)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.startCount, 1)
        XCTAssertEqual(metrics.maximumConcurrentLifecycleCalls, 1)
    }

    func testCancelWaitsForInFlightStartWithoutOverlappingClientLifecycle() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)

        let start = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        let cancel = Task { await session.cancel() }
        await client.releaseStart()

        do {
            try await start.value
        } catch {
            XCTFail("Unexpected start failure: \(error)")
        }
        await cancel.value

        XCTAssertEqual(session.state, .idle)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.maximumConcurrentLifecycleCalls, 1)
        XCTAssertEqual(
            metrics.lifecycleLog,
            ["start.begin", "start.end", "cancel.begin", "cancel.end"]
        )
    }

    func testTerminalEventDuringStartPreventsRecordingTransition() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)
        let terminalObserved = Task { () -> Bool in
            for await event in session.events {
                if case .state(.failed(let failure)) = event,
                   failure.code == .connectionLost { return true }
            }
            return false
        }

        let start = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        let failure = ASRFailure(code: .connectionLost)
        await client.emit(.state(.failed(failure)))
        let didObserveTerminal = await terminalObserved.value
        XCTAssertTrue(didObserveTerminal)
        await client.releaseStart()

        do {
            try await start.value
        } catch {
            XCTFail("Unexpected start failure: \(error)")
        }
        XCTAssertEqual(session.state, .failed(failure))
    }

    func testCancelDuringStartInvalidatesRecordingTransition() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)
        let recordingObservedBeforeIdle = Task { () -> Bool in
            for await event in session.events {
                if case .state(.recording) = event { return true }
                if case .state(.idle) = event { return false }
            }
            return false
        }

        let start = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        let cancel = Task { await session.cancel() }
        await waitUntil { session.state == .idle }
        XCTAssertEqual(session.state, .idle)
        let didObserveRecording = await recordingObservedBeforeIdle.value
        XCTAssertFalse(didObserveRecording)
        let restartError: ASRSession.SessionError?
        do {
            try await session.startStream()
            restartError = nil
        } catch let error as ASRSession.SessionError {
            restartError = error
        } catch {
            restartError = nil
        }
        XCTAssertEqual(restartError, .busy)
        await client.releaseStart()

        do {
            try await start.value
        } catch {
            XCTFail("Unexpected start failure: \(error)")
        }
        await cancel.value

        XCTAssertEqual(session.state, .idle)
        let metrics = await client.metrics()
        XCTAssertEqual(
            metrics.lifecycleLog,
            ["start.begin", "start.end", "cancel.begin", "cancel.end"]
        )
    }

    func testTerminalEventCapturedBeforeCancelCannotFailRestartedGeneration() async {
        let client = ControllableASRSessionClient()
        let deliveryGate = OneShotClientEventDeliveryGate()
        let session = ASRSession(
            client: client,
            beforeHandlingClientEvent: { event in
                await deliveryGate.pauseOnce(event)
            }
        )

        let firstStart = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        await client.releaseStart()
        do {
            try await firstStart.value
        } catch {
            XCTFail("Unexpected first start failure: \(error)")
        }

        await client.emit(.state(.failed(.init(code: .connectionLost))))
        await deliveryGate.waitUntilPaused()
        await session.cancel()

        let restart = Task { try await session.startStream() }
        await client.waitUntilSecondStartEntered()
        await client.releaseStart()
        do {
            try await restart.value
        } catch {
            XCTFail("Unexpected restart failure: \(error)")
        }

        let currentTranscriptObserved = Task { () -> Bool in
            for await event in session.events {
                if case .transcript("current_generation") = event { return true }
            }
            return false
        }
        await deliveryGate.release()
        await client.emit(.transcript("current_generation"))
        let didObserveCurrentTranscript = await currentTranscriptObserved.value
        XCTAssertTrue(didObserveCurrentTranscript)
        XCTAssertEqual(session.state, .recording)
    }

    func testBufferedTerminalBeforeCancelBarrierCannotFailRestartedGeneration() async {
        let client = ControllableASRSessionClient()
        let deliveryGate = OneShotClientEventDeliveryGate()
        let session = ASRSession(
            client: client,
            beforeHandlingClientEvent: { event in
                await deliveryGate.pauseOnce(event)
            }
        )

        let firstStart = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        await client.releaseStart()
        do {
            try await firstStart.value
        } catch {
            XCTFail("Unexpected first start failure: \(error)")
        }

        await client.emit(.transcript("delivery_blocker"))
        await deliveryGate.waitUntilPaused()
        await client.emit(.state(.failed(.init(code: .connectionLost))))
        await session.cancel()

        let restart = Task { try await session.startStream() }
        await client.waitUntilSecondStartEntered()
        await client.releaseStart()
        do {
            try await restart.value
        } catch {
            XCTFail("Unexpected restart failure: \(error)")
        }

        let currentTranscriptObserved = Task { () -> Bool in
            for await event in session.events {
                if case .transcript("post_barrier_generation") = event { return true }
            }
            return false
        }
        await deliveryGate.release()
        await client.emit(.transcript("post_barrier_generation"))
        let didObserveCurrentTranscript = await currentTranscriptObserved.value

        XCTAssertTrue(didObserveCurrentTranscript)
        XCTAssertEqual(session.state, .recording)
    }

    func testFinishWaitsForInFlightAudioPushWithoutOverlappingClientCalls() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)
        let start = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        await client.releaseStart()
        do {
            try await start.value
        } catch {
            XCTFail("Unexpected start failure: \(error)")
        }

        session.pushAudio(Data([0x01, 0x02]))
        await client.waitUntilPushEntered()
        let finish = Task { await session.finish() }
        await client.releasePush()
        await finish.value

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.maximumConcurrentLifecycleCalls, 1)
        XCTAssertEqual(
            metrics.lifecycleLog,
            [
                "start.begin", "start.end",
                "push.begin", "push.end",
                "finish.begin", "finish.end"
            ]
        )
    }

    func testCancelWaitsForInFlightAudioPushWithoutOverlappingClientCalls() async {
        let client = ControllableASRSessionClient()
        let session = ASRSession(client: client)
        let start = Task { try await session.startStream() }
        await client.waitUntilStartEntered()
        await client.releaseStart()
        do {
            try await start.value
        } catch {
            XCTFail("Unexpected start failure: \(error)")
        }

        session.pushAudio(Data([0x03, 0x04]))
        await client.waitUntilPushEntered()
        let cancel = Task { await session.cancel() }
        await client.releasePush()
        await cancel.value

        XCTAssertEqual(session.state, .idle)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.maximumConcurrentLifecycleCalls, 1)
        XCTAssertEqual(
            metrics.lifecycleLog,
            [
                "start.begin", "start.end",
                "push.begin", "push.end",
                "cancel.begin", "cancel.end"
            ]
        )
    }

    func testSessionDeallocatesWhileClientEventStreamRemainsOpen() async {
        let client = ControllableASRSessionClient()
        weak var weakSession: ASRSession?

        do {
            let session = ASRSession(client: client)
            weakSession = session
            XCTAssertNotNil(weakSession)
        }

        for _ in 0..<10 where weakSession != nil {
            await Task.yield()
        }
        XCTAssertNil(weakSession)
    }

    func testSessionDeallocatesAfterCancelWhileClientEventStreamRemainsOpen() async {
        let client = ControllableASRSessionClient()
        weak var weakSession: ASRSession?

        do {
            let session = ASRSession(client: client)
            weakSession = session
            let start = Task { try await session.startStream() }
            await client.waitUntilStartEntered()
            await client.releaseStart()
            do {
                try await start.value
            } catch {
                XCTFail("Unexpected start failure: \(error)")
            }
            await session.cancel()
        }

        for _ in 0..<10 where weakSession != nil {
            await Task.yield()
        }
        XCTAssertNil(weakSession)
    }

    func testSessionDeallocatesAfterFinishWhileClientEventStreamRemainsOpen() async {
        let client = ControllableASRSessionClient()
        weak var weakSession: ASRSession?

        do {
            let session = ASRSession(client: client)
            weakSession = session
            let start = Task { try await session.startStream() }
            await client.waitUntilStartEntered()
            await client.releaseStart()
            do {
                try await start.value
            } catch {
                XCTFail("Unexpected start failure: \(error)")
            }
            await session.finish()
        }

        for _ in 0..<10 where weakSession != nil {
            await Task.yield()
        }
        XCTAssertNil(weakSession)
    }

    func testInjectedTransportStartFailureIsSurfacedWithoutRetry() async {
        let client = FaultingASRSessionClient(startFailure: .unknownFixture)
        let session = ASRSession(client: client)

        do {
            try await session.startStream()
            XCTFail("Expected injected transport failure")
        } catch let error as ASRFailure {
            XCTAssertEqual(error.code, .unknown)
            XCTAssertFalse(error.userSafeMessage?.contains("未审核的传输详情") == true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        guard case .failed(let failure) = session.state else {
            return XCTFail("Expected typed failed state")
        }
        XCTAssertEqual(failure.code, .unknown)
        XCTAssertFalse(failure.userSafeMessage?.contains("未审核的传输详情") == true)
        let startCount = await client.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testInjectedTransport401AfterTranscriptDoesNotRetryOrHidePublishedContent() async throws {
        let client = FaultingASRSessionClient()
        let session = ASRSession(client: client)
        let observation = Task { () -> [ASRSession.Event] in
            var observed: [ASRSession.Event] = []
            for await event in session.events {
                observed.append(event)
                if case .state(.failed) = event { return observed }
            }
            return observed
        }

        try await session.startStream()
        await client.emit(.transcript("已发布文本"))
        await client.emit(.state(.failed(.providerStatus(401))))
        let observed = await observation.value

        XCTAssertTrue(observed.contains { if case .transcript("已发布文本") = $0 { true } else { false } })
        XCTAssertTrue(observed.contains {
            if case .state(.failed(let failure)) = $0 { failure.code == .unauthorized } else { false }
        })
        let startCount = await client.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testTransportClassificationUsesCodesAndNeverLocalizedDescriptions() async {
        for (urlCode, expectedCode) in [
            (URLError.timedOut, ASRFailure.Code.timeout),
            (URLError.networkConnectionLost, ASRFailure.Code.connectionLost)
        ] {
            let client = FaultingASRSessionClient(startFailure: .url(urlCode))
            let session = ASRSession(client: client)

            do {
                try await session.startStream()
                XCTFail("Expected typed transport failure")
            } catch let failure as ASRFailure {
                XCTAssertEqual(failure.code, expectedCode)
                XCTAssertFalse(failure.userSafeMessage?.contains("非英语本地化原始详情") == true)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            guard case .failed(let stateFailure) = session.state else {
                return XCTFail("Expected typed failed state")
            }
            XCTAssertEqual(stateFailure.code, expectedCode)
            XCTAssertFalse(stateFailure.userSafeMessage?.contains("非英语本地化原始详情") == true)
            let startCount = await client.startCount
            XCTAssertEqual(startCount, 1)
        }
    }
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool,
    maxYields: Int = 1_000
) async {
    for _ in 0..<maxYields {
        if predicate() { return }
        await Task.yield()
    }
}

private actor OneShotClientEventDeliveryGate {
    private var shouldPause = true
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseOnce(_ event: ASRClient.Event) async {
        guard shouldPause else { return }
        shouldPause = false
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            isPaused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum FaultingStartFailure: Sendable {
    case unknownFixture
    case url(URLError.Code)
}

private actor FaultingASRSessionClient: ASRSessionClient {
    nonisolated let events: AsyncStream<ASRClient.Event>
    private let continuation: AsyncStream<ASRClient.Event>.Continuation
    private let startFailure: FaultingStartFailure?
    private(set) var startCount = 0

    init(startFailure: FaultingStartFailure? = nil) {
        self.startFailure = startFailure
        let (events, continuation) = AsyncStream<ASRClient.Event>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func start() async throws {
        startCount += 1
        if let startFailure {
            switch startFailure {
            case .unknownFixture:
                throw NSError(
                    domain: "tests.transport",
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: "未审核的传输详情"]
                )
            case .url(let code):
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: code.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "非英语本地化原始详情"]
                )
            }
        }
        continuation.yield(.state(.connecting))
        continuation.yield(.state(.streaming))
    }

    func pushAudio(_ data: Data) async {}
    func finish() async {}
    func cancel() async { continuation.yield(.state(.idle)) }
    func emit(_ event: ASRClient.Event) { continuation.yield(event) }
}

private actor ControllableASRSessionClient: ASRSessionClient {
    struct Metrics: Sendable {
        let startCount: Int
        let maximumConcurrentLifecycleCalls: Int
        let lifecycleLog: [String]
    }

    nonisolated let events: AsyncStream<ASRClient.Event>
    private let eventsContinuation: AsyncStream<ASRClient.Event>.Continuation
    private var startCount = 0
    private var activeLifecycleCalls = 0
    private var maximumConcurrentLifecycleCalls = 0
    private var lifecycleLog: [String] = []
    private var startRelease: CheckedContinuation<Void, Never>?
    private var startEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var pushRelease: CheckedContinuation<Void, Never>?
    private var pushEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        let (events, continuation) = AsyncStream<ASRClient.Event>.makeStream()
        self.events = events
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
        startRelease?.resume()
        startEntryWaiters.forEach { $0.resume() }
        pushRelease?.resume()
        pushEntryWaiters.forEach { $0.resume() }
    }

    func start() async throws {
        beginLifecycle("start.begin")
        startCount += 1
        eventsContinuation.yield(.state(.connecting))
        let waiters = startEntryWaiters
        startEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            startRelease = continuation
        }
        startRelease = nil
        eventsContinuation.yield(.state(.streaming))
        endLifecycle("start.end")
    }

    func pushAudio(_ data: Data) async {
        beginLifecycle("push.begin")
        let waiters = pushEntryWaiters
        pushEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            pushRelease = continuation
        }
        pushRelease = nil
        endLifecycle("push.end")
    }

    func finish() async {
        beginLifecycle("finish.begin")
        endLifecycle("finish.end")
    }

    func cancel() async {
        beginLifecycle("cancel.begin")
        eventsContinuation.yield(.state(.idle))
        endLifecycle("cancel.end")
    }

    func emit(_ event: ASRClient.Event) {
        eventsContinuation.yield(event)
    }

    func waitUntilStartEntered() async {
        guard startCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startEntryWaiters.append(continuation)
        }
    }

    func waitUntilSecondStartEntered() async {
        guard startCount < 2 else { return }
        await withCheckedContinuation { continuation in
            startEntryWaiters.append(continuation)
        }
    }

    func releaseStart() {
        startRelease?.resume()
        startRelease = nil
    }

    func waitUntilPushEntered() async {
        guard pushRelease == nil else { return }
        await withCheckedContinuation { continuation in
            pushEntryWaiters.append(continuation)
        }
    }

    func releasePush() {
        pushRelease?.resume()
        pushRelease = nil
    }

    func metrics() -> Metrics {
        Metrics(
            startCount: startCount,
            maximumConcurrentLifecycleCalls: maximumConcurrentLifecycleCalls,
            lifecycleLog: lifecycleLog
        )
    }

    private func beginLifecycle(_ entry: String) {
        activeLifecycleCalls += 1
        maximumConcurrentLifecycleCalls = max(maximumConcurrentLifecycleCalls, activeLifecycleCalls)
        lifecycleLog.append(entry)
    }

    private func endLifecycle(_ entry: String) {
        lifecycleLog.append(entry)
        activeLifecycleCalls -= 1
    }
}
