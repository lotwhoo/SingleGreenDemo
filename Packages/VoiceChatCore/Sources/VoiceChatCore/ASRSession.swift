import Foundation
import os

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
///         case .transcript(let text):  print("实时转写: \(text)")
///         case .state(.finished):      print("识别完成")
///         case .state(.failed(let m)): print("失败: \(m)")
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

    public enum State: Sendable, Equatable {
        case idle          // 空闲
        case starting      // 建连中
        case recording     // 录音/流式中
        case finalizing    // 已停止，等待最终结果
        case finished      // 完成（收到最终结果）
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        case transcript(String)   // 实时增量转写
        case utterance(String)    // 定型句
        case level(Float)         // 录音电平 0~1
        case error(String)
    }

    public enum SessionError: Error, LocalizedError, Equatable {
        case busy                 // 会话进行中，不能重复 start
        case notRunning           // 会话未启动

        public var errorDescription: String? {
            switch self {
            case .busy: return "ASR 会话已在进行中"
            case .notRunning: return "ASR 会话未启动"
            }
        }
    }

    // MARK: - 内部状态

    private let config: Config
    private let client: ASRClient
    private let audio: AudioCapture?
    private var eventsCont: AsyncStream<Event>.Continuation?
    private var clientEventsTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var _state: State = .idle

    /// 事件流（可在任意线程订阅）。
    public let events: AsyncStream<Event>

    public init(config: Config) {
        self.config = config
        self.client = ASRClient(config: ASRClient.Config(
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
        self.audio = AudioCapture()
        #else
        self.audio = nil
        #endif
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.eventsCont = cont

        self.clientEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events {
                self.handleClientEvent(event)
            }
        }
    }

    deinit {
        clientEventsTask?.cancel()
        eventsCont?.finish()
    }

    // MARK: - 对外接口

    /// 当前状态（线程安全）。
    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    /// 麦克风模式：建连 + 开始录音（自动 200ms 切包推送）。仅 iOS。
    public func start() async throws {
        guard state == .idle else { throw SessionError.busy }
        setState(.starting)
        do {
            try await client.start()
            try audio?.start { [weak self] chunk in
                guard let self else { return }
                Task { await self.client.pushAudio(chunk) }
            } levelHandler: { [weak self] level in
                self?.emit(.level(level))
            }
            setState(.recording)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// 手动喂流模式：只建连，音频由调用方通过 `pushAudio(_:)` 提供。
    public func startStream() async throws {
        guard state == .idle else { throw SessionError.busy }
        setState(.starting)
        do {
            try await client.start()
            setState(.recording)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    /// 推送 PCM 音频包（16kHz/16bit/单声道，任意大小，内部自动 200ms 切包）。手动模式用。
    public func pushAudio(_ data: Data) {
        Task { await client.pushAudio(data) }
    }

    /// 结束本次识别：停止录音（iOS）、发送末尾帧，等待最终结果（`finished` 事件）。
    public func finish() async {
        let current = state
        guard current == .recording || current == .starting else { return }
        setState(.finalizing)
        audio?.stop()
        await client.finish()
    }

    /// 硬取消：丢弃本次识别并断开连接，回到 `idle`。
    public func cancel() async {
        audio?.stop(flushRemainder: false)
        await client.cancel()
        setState(.idle)
    }

    // MARK: - 内部

    private func handleClientEvent(_ event: ASRClient.Event) {
        switch event {
        case .state(let clientState):
            switch clientState {
            case .finished:
                // 只 emit 一次（setState 不再内部 emit，避免重复事件）
                updateState(.finished)
                emit(.state(.finished))
            case .failed(let message):
                updateState(.failed(message))
                emit(.state(.failed(message)))
            default:
                break
            }
        case .transcript(let text):
            emit(.transcript(text))
        case .utterance(let text):
            emit(.utterance(text))
        case .error(let message):
            emit(.error(message))
        }
    }

    /// 更新内部状态并 emit（供控制方法使用）。
    private func setState(_ newState: State) {
        updateState(newState)
        emit(.state(newState))
    }

    /// 只更新内部状态，不 emit（由调用方负责 emit，防止重复事件）。
    private func updateState(_ newState: State) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
    }

    private func emit(_ event: Event) {
        eventsCont?.yield(event)
    }
}
