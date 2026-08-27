import Foundation
import os

/// ASR 客户端统一日志（真机诊断用：macOS `log stream --device` 可远程拉取）。
let asrLogger = Logger(subsystem: "com.lotwho.voicechat", category: "asr-client")

/// 豆包流式语音识别 2.0 WebSocket 客户端（SAUC 协议）。
///
/// 用法（App 侧）：
/// ```
/// let client = ASRClient(config: .init(apiKey: key, resourceID: "volc.seedasr.sauc.duration"))
/// let eventsTask = Task { for await e in client.events { ... } }
/// try await client.start()
/// client.pushAudio(chunk)   // 200ms PCM 包
/// client.finish()           // 结束本次识别
/// ```
public actor ASRClient {

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

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case streaming
        case finished
        case failed(String)
    }

    public enum Event: Sendable {
        case state(State)
        case transcript(String)       // 整段增量文本（实时上屏用）
        case utterance(String)        // 已定型的句子
        case error(String)
    }

    private let config: Config
    private var task: URLSessionWebSocketTask?
    private var eventsCont: AsyncStream<Event>.Continuation?
    private var audioCont: AsyncStream<Data>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var isFinishing = false

    /// 事件流（可在 actor 外订阅）。
    public nonisolated let events: AsyncStream<Event>

    public init(config: Config) {
        self.config = config
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.eventsCont = cont
    }

    // MARK: - 控制

    public func start() async throws {
        guard task == nil else { return }
        guard let url = URL(string: "wss://\(config.host)\(config.path)") else {
            throw ASRError.invalidURL
        }
        asrLogger.info("连接 \(url.absoluteString, privacy: .public)  resourceID=\(self.config.resourceID, privacy: .public)  language=\(self.config.language, privacy: .public)")

        var request = URLRequest(url: url)
        request.timeoutInterval = config.timeoutInterval
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        task = ws
        isFinishing = false
        emit(.state(.connecting))
        ws.resume()

        // 起始帧
        var requestConfig = ASRStartRequest.Request(enableITN: config.enableITN,
                                                    enablePunc: config.enablePunc,
                                                    showUtterances: config.showUtterances)
        if !config.hotwords.isEmpty {
            let words = config.hotwords.map { ["word": $0] }
            if let contextData = try? JSONSerialization.data(withJSONObject: ["hotwords": words]),
               let context = String(data: contextData, encoding: .utf8) {
                requestConfig.corpus = .init(context: context)
            }
        }
        let start = ASRStartRequest(
            user: .init(uid: "ios-voicechat"),
            audio: .init(language: config.language),
            request: requestConfig
        )
        let json = try JSONEncoder().encode(start)
        let gz = Gzip.compress(json) ?? json
        let startFrame = SAUC.clientFrame(messageType: .fullClientRequest,
                                          flags: .noSequence,
                                          payload: gz)
        try await ws.send(.data(startFrame))
        asrLogger.info("起始帧已发送")
        emit(.state(.streaming))

        // 接收循环
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // 音频泵：pushAudio 的包逐个发送，流结束发末尾帧
        let (stream2, cont2) = AsyncStream<Data>.makeStream()
        audioCont = cont2
        audioPumpTask = Task { [weak self] in
            var packetCount = 0
            for await chunk in stream2 {
                try? await self?.sendAudioFrame(chunk, final: false)
                packetCount += 1
            }
            asrLogger.info("音频包发送完毕，共 \(packetCount, privacy: .public) 包，发送末尾帧")
            try? await self?.sendAudioFrame(Data(), final: true)
            await self?.markFinishing()
        }
    }

    /// 推送一个 PCM 音频包（200ms / 6400 字节 @ 16kHz-16bit-mono）。线程安全，可从录音回调调用。
    public func pushAudio(_ data: Data) {
        audioCont?.yield(data)
    }

    /// 结束本次识别（发送末尾帧，等待最终结果）。
    public func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        audioCont?.finish()
    }

    /// 硬取消：放弃本次识别并断开。
    public func cancel() {
        audioCont?.finish()
        receiveTask?.cancel()
        audioPumpTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        emit(.state(.idle))
    }

    // MARK: - 内部

    private func markFinishing() {
        isFinishing = true
    }

    private func sendAudioFrame(_ data: Data, final: Bool) async throws {
        guard let ws = task else { return }
        let gz = Gzip.compress(data) ?? data
        let frame = SAUC.clientFrame(messageType: .audioOnlyRequest,
                                     flags: final ? .finalNoSequence : .noSequence,
                                     serialization: 0,
                                     payload: gz)
        try await ws.send(.data(frame))
    }

    private func receiveLoop() async {
        guard let ws = task else { return }
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .data(let data):
                    handleServerData(data)
                case .string(let text):
                    handleServerText(text)
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    emit(.state(.failed(error.localizedDescription)))
                }
                break
            }
        }
    }

    private func handleServerData(_ data: Data) {
        do {
            let frame = try SAUC.parseServerFrame(data)
            switch frame.messageType {
            case .fullServerResponse:
                guard let obj = try? JSONDecoder().decode(ASRResponse.self, from: frame.payload) else {
                    return
                }
                if let text = obj.result?.text, !text.isEmpty {
                    emit(.transcript(text))
                    asrLogger.info("增量: \(text, privacy: .public)")
                }
                if let utterances = obj.result?.utterances {
                    for utt in utterances {
                        if let t = utt.text, utt.definite == true {
                            emit(.utterance(t))
                        }
                    }
                }
                if frame.flags == .finalNegativeSequence {
                    asrLogger.info("收到最终结果，关闭连接")
                    emit(.state(.finished))
                    task?.cancel(with: .normalClosure, reason: nil)
                    task = nil
                    receiveTask?.cancel()
                }
            case .error:
                let (code, msg) = try SAUC.parseErrorFrame(data)
                asrLogger.error("SAUC 错误帧: \(code, privacy: .public) \(msg, privacy: .public)")
                emit(.state(.failed("\(code): \(msg)")))
            default:
                break
            }
        } catch {
            emit(.state(.failed(error.localizedDescription)))
        }
    }

    private func handleServerText(_ text: String) {
        // 服务端一般只用二进制帧；文本帧兜底解析 JSON。
        if let data = text.data(using: .utf8),
           let obj = try? JSONDecoder().decode(ASRResponse.self, from: data),
           let t = obj.result?.text, !t.isEmpty {
            emit(.transcript(t))
        }
    }

    private func emit(_ event: Event) {
        eventsCont?.yield(event)
    }
}

public enum ASRError: Error, Sendable, LocalizedError {
    case invalidURL
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 WebSocket URL"
        }
    }
}
