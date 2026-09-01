import Foundation
import os
import ASRDomain

/// 豆包流式语音识别 2.0 高层模块。
///
/// 封装了「录音 → 16kHz PCM 切包 → SAUC WebSocket 流式推送 → 增量转写」完整流程，
/// 与 UI 完全解耦。任何 iOS/macOS 项目只需几步即可接入：
///
/// ```swift
/// let session = ASRSession(config: .init(apiKey: "你的API Key"))
/// let eventsTask = Task {
///     for await event in session.events {
///         switch event {
///         case .transcript(let text):  print("收到转写更新（\(text.count) 字符）")
///         case .state(.finished):      print("识别完成")
///         case .state(.failed):        print("识别失败")
///         default: break
///         }
///     }
/// }
/// try await session.start()   // 开始录音 + 识别
/// session.finish()            // 结束
/// ```
///
/// 支持两种输入模式：
/// - 麦克风模式：`start()` 自动录音（iOS）
/// - 手动喂流模式：`startStream()` + `pushAudio(_:)` 推送 PCM 包
///
/// The synchronous control method names are retained. Failure payloads now use `ASRFailure`, an
/// intentional local-package API migration. Internal state is lock protected, while complete
/// asynchronous lifecycle operations are serialized so their client calls cannot overlap.
public final class ASRSession: @unchecked Sendable {

    // MARK: - 配置

    public struct Config: Sendable, Equatable {
        public var apiKey: String
        public var resourceID: String
        public var host: String
        public var path: String
        public var language: String
        public var enableITN: Bool
        public var enablePunc: Bool
        public var showUtterances: Bool
        public var hotwords: [String]
        public var timeoutInterval: TimeInterval

        public init(apiKey: String,
                    resourceID: String = "volc.seedasr.sauc.duration",
                    host: String = "openspeech.bytedance.com",
                    path: String = "/api/v3/sauc/bigmodel",
                    language: String = "zh-CN",
                    enableITN: Bool = true,
                    enablePunc: Bool = true,
                    showUtterances: Bool = true,
                    hotwords: [String] = [],
                    timeoutInterval: TimeInterval = 30) {
            self.apiKey = apiKey
            self.resourceID = resourceID
            self.host = host
            self.path = path
            self.language = language
            self.enableITN = enableITN
            self.enablePunc = enablePunc
            self.showUtterances = showUtterances
            self.hotwords = hotwords
            self.timeoutInterval = timeoutInterval
        }
    }

    // MARK: - 状态与事件

    public typealias State = ASRSessionState
    public typealias Event = ASRSessionEvent
    public typealias SessionError = ASRSessionError

    // MARK: - 内部状态

    private let client: any ASRSessionClient
    private let audio: AudioCapture?
    private let storage: ASRSessionStorage
    private let lifecycleGate = AsyncLifecycleGate()
    private let clientEventsTask: Task<Void, Never>

    /// 事件流（可在任意线程订阅）。
    public let events: AsyncStream<Event>

    public convenience init(config: Config) {
        let client = ASRClient(config: ASRClient.Config(
            apiKey: config.apiKey,
            resourceID: config.resourceID,
            host: config.host,
            path: config.path,
            language: config.language,
            enableITN: config.enableITN,
            enablePunc: config.enablePunc,
            showUtterances: config.showUtterances,
            hotwords: config.hotwords,
            timeoutInterval: config.timeoutInterval
        ))
        #if os(iOS)
        self.init(client: client, audio: AudioCapture())
        #else
        self.init(client: client, audio: nil)
        #endif
    }

    init(
        client: any ASRSessionClient,
        audio: AudioCapture? = nil,
        beforeHandlingClientEvent: @escaping @Sendable (ASRClient.Event) async -> Void = { _ in }
    ) {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let storage = ASRSessionStorage(continuation: continuation)
        let clientEvents = client.events

        self.client = client
        self.audio = audio
        self.storage = storage
        self.events = stream
        self.clientEventsTask = Task { [weak storage] in
            for await event in clientEvents {
                guard let storage,
                      let generation = storage.generationForClientEvent(event) else { continue }
                await beforeHandlingClientEvent(event)
                storage.handleClientEvent(event, generation: generation)
            }
        }
    }

    deinit {
        clientEventsTask.cancel()
        storage.finishEvents()
    }

    // MARK: - 对外接口

    /// 当前状态（线程安全）。
    public var state: State {
        storage.state
    }

    /// 麦克风模式：建连 + 开始录音（自动 200ms 切包推送）。仅 iOS。
    public func start() async throws {
        guard let generation = storage.beginStarting() else { throw SessionError.busy }
        try await lifecycleGate.withLock { [self] in
            guard storage.isStarting(generation: generation) else { return }
            do {
                try await client.start()
                guard storage.isStarting(generation: generation) else { return }
                try audio?.start { [weak self] chunk in
                    self?.pushAudio(chunk, generation: generation)
                } levelHandler: { [weak storage] level in
                    storage?.emit(.level(level), generation: generation)
                }
                guard storage.transitionToRecording(generation: generation) else {
                    audio?.stop(flushRemainder: false)
                    return
                }
            } catch {
                let failure = ASRFailure.transport(error)
                storage.failStarting(failure, generation: generation)
                throw failure
            }
        }
    }

    /// 手动喂流模式：只建连，音频由调用方通过 `pushAudio(_:)` 提供。
    public func startStream() async throws {
        guard let generation = storage.beginStarting() else { throw SessionError.busy }
        try await lifecycleGate.withLock { [self] in
            guard storage.isStarting(generation: generation) else { return }
            do {
                try await client.start()
                storage.transitionToRecording(generation: generation)
            } catch {
                let failure = ASRFailure.transport(error)
                storage.failStarting(failure, generation: generation)
                throw failure
            }
        }
    }

    /// 推送 PCM 音频包（16kHz/16bit/单声道，任意大小，内部自动 200ms 切包）。手动模式用。
    public func pushAudio(_ data: Data) {
        guard let generation = storage.generationForAudioPush else { return }
        pushAudio(data, generation: generation)
    }

    private func pushAudio(_ data: Data, generation: UInt64) {
        let client = client
        let lifecycleGate = lifecycleGate
        let storage = storage
        Task {
            await lifecycleGate.withLock {
                guard storage.canPushAudio(generation: generation) else { return }
                await client.pushAudio(data)
            }
        }
    }

    /// 结束本次识别：停止录音（iOS）、发送末尾帧，等待最终结果（`finished` 事件）。
    public func finish() async {
        guard let generation = storage.beginFinalizing() else { return }
        await lifecycleGate.withLock { [self] in
            guard storage.isFinalizing(generation: generation) else { return }
            audio?.stop()
            await client.finish()
        }
    }

    /// 硬取消：丢弃本次识别并断开连接，回到 `idle`。
    public func cancel() async {
        let cancellationGeneration = storage.beginCancellingCurrentGeneration()
        await lifecycleGate.withLock { [self] in
            audio?.stop(flushRemainder: false)
            await client.cancel()
        }
        storage.completeCancellation(generation: cancellationGeneration)
    }
}

protocol ASRSessionClient: Sendable {
    /// Lifecycle markers delimit event generations: a successful start emits connecting/streaming,
    /// and cancel emits idle before returning so buffered events cannot cross into a restarted session.
    var events: AsyncStream<ASRClient.Event> { get }
    func start() async throws
    func pushAudio(_ data: Data) async
    func finish() async
    func cancel() async
}

extension ASRClient: ASRSessionClient {}

private actor AsyncLifecycleGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private final class ASRSessionStorage: Sendable {
    private struct Values: Sendable {
        var state: ASRSession.State = .idle
        var generation: UInt64 = 0
        var activeGeneration: UInt64?
        var clientEventGeneration: UInt64?
        var awaitsClientIdleBarrier = false
        var cancellationGeneration: UInt64?
        var eventsFinished = false
    }

    private let values = OSAllocatedUnfairLock(initialState: Values())
    private let continuation: AsyncStream<ASRSession.Event>.Continuation

    init(continuation: AsyncStream<ASRSession.Event>.Continuation) {
        self.continuation = continuation
    }

    var state: ASRSession.State {
        values.withLock { $0.state }
    }

    var generationForAudioPush: UInt64? {
        values.withLock { values in
            guard values.state == .recording else { return nil }
            return values.activeGeneration
        }
    }

    func beginStarting() -> UInt64? {
        values.withLock { values -> UInt64? in
            guard values.state == .idle,
                  values.cancellationGeneration == nil else { return nil }
            values.generation &+= 1
            values.activeGeneration = values.generation
            values.state = .starting
            if !values.eventsFinished { continuation.yield(.state(.starting)) }
            return values.generation
        }
    }

    func isStarting(generation: UInt64) -> Bool {
        values.withLock {
            $0.activeGeneration == generation && $0.state == .starting
        }
    }

    @discardableResult
    func transitionToRecording(generation: UInt64) -> Bool {
        values.withLock { values in
            guard values.activeGeneration == generation,
                  values.state == .starting else { return false }
            values.state = .recording
            if !values.eventsFinished { continuation.yield(.state(.recording)) }
            return true
        }
    }

    func failStarting(_ failure: ASRFailure, generation: UInt64) {
        values.withLock { values in
            guard values.activeGeneration == generation,
                  values.state == .starting else { return }
            values.state = .failed(failure)
            values.activeGeneration = nil
            if !values.eventsFinished { continuation.yield(.state(.failed(failure))) }
        }
    }

    func beginFinalizing() -> UInt64? {
        values.withLock { values -> UInt64? in
            guard let generation = values.activeGeneration,
                  values.state == .recording || values.state == .starting else { return nil }
            values.state = .finalizing
            if !values.eventsFinished { continuation.yield(.state(.finalizing)) }
            return generation
        }
    }

    func isFinalizing(generation: UInt64) -> Bool {
        values.withLock {
            $0.activeGeneration == generation && $0.state == .finalizing
        }
    }

    func canPushAudio(generation: UInt64) -> Bool {
        values.withLock {
            $0.activeGeneration == generation && $0.state == .recording
        }
    }

    func beginCancellingCurrentGeneration() -> UInt64 {
        values.withLock { values -> UInt64 in
            values.generation &+= 1
            values.activeGeneration = nil
            values.clientEventGeneration = nil
            values.awaitsClientIdleBarrier = true
            values.cancellationGeneration = values.generation
            values.state = .idle
            if !values.eventsFinished { continuation.yield(.state(.idle)) }
            return values.generation
        }
    }

    func completeCancellation(generation: UInt64) {
        values.withLock { values in
            guard values.cancellationGeneration == generation else { return }
            values.cancellationGeneration = nil
        }
    }

    func emit(_ event: ASRSession.Event, generation: UInt64) {
        values.withLock { values in
            guard values.activeGeneration == generation else { return }
            switch values.state {
            case .starting, .recording, .finalizing:
                if !values.eventsFinished { continuation.yield(event) }
            case .idle, .finished, .failed:
                return
            }
        }
    }

    func generationForClientEvent(_ event: ASRClient.Event) -> UInt64? {
        values.withLock { values in
            if case .state(let clientState) = event {
                switch clientState {
                case .idle:
                    values.awaitsClientIdleBarrier = false
                    values.clientEventGeneration = nil
                    return nil
                case .connecting, .streaming:
                    guard !values.awaitsClientIdleBarrier,
                          let generation = values.activeGeneration else { return nil }
                    values.clientEventGeneration = generation
                    return nil
                case .finished, .failed:
                    break
                }
            }
            return values.clientEventGeneration
        }
    }

    func finishEvents() {
        let shouldFinish = values.withLock { values in
            guard !values.eventsFinished else { return false }
            values.eventsFinished = true
            return true
        }
        if shouldFinish { continuation.finish() }
    }

    func handleClientEvent(_ event: ASRClient.Event, generation: UInt64) {
        switch event {
        case .state(let clientState):
            switch clientState {
            case .finished:
                acceptTerminalState(.finished, generation: generation)
            case .failed(let failure):
                acceptTerminalState(.failed(failure), generation: generation)
            default:
                break
            }
        case .transcript(let text):
            emit(.transcript(text), generation: generation)
        case .utterance(let text):
            emit(.utterance(text), generation: generation)
        case .error(let failure):
            emit(.error(failure), generation: generation)
        }
    }

    private func acceptTerminalState(_ state: ASRSession.State, generation: UInt64) {
        values.withLock { values in
            guard values.activeGeneration == generation else { return }
            switch values.state {
            case .starting, .recording, .finalizing:
                values.state = state
                values.activeGeneration = nil
                values.clientEventGeneration = nil
                if !values.eventsFinished { continuation.yield(.state(state)) }
            case .idle, .finished, .failed:
                return
            }
        }
    }
}
