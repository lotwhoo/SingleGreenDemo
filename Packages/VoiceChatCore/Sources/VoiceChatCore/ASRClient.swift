import Foundation
import os
import VoiceActivityDetectionKit

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
        case failed(ASRFailure)
    }

    public enum Event: Sendable {
        case state(State)
        case transcript(String)       // 整段增量文本（实时上屏用）
        case utterance(String)        // 已定型的句子
        case error(ASRFailure)
    }

    private let config: Config
    private let frameSender: (@Sendable (Data, Bool) async throws -> Void)?
    private var task: URLSessionWebSocketTask?
    private var eventsCont: AsyncStream<Event>.Continuation?
    private var audioCont: AsyncStream<Data>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var isFinishing = false
    private var terminalDelivered = false
    private var connectionMode: ConnectionMode?

    private enum ConnectionMode: Equatable {
        case legacyQueue
        case direct
    }

    private enum TerminalOutcome {
        case finished
        case failed(ASRFailure)
    }

    /// 事件流（可在 actor 外订阅）。
    public nonisolated let events: AsyncStream<Event>
    private var directEventsCont: AsyncStream<StreamingASRTransportEvent>.Continuation?

    public init(config: Config) {
        self.config = config
        self.frameSender = nil
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.eventsCont = cont
    }

    init(
        config: Config,
        frameSender: @escaping @Sendable (Data, Bool) async throws -> Void
    ) {
        self.config = config
        self.frameSender = frameSender
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.eventsCont = cont
    }

    // MARK: - 控制

    public func start() async throws {
        guard try await openConnection(mode: .legacyQueue) else { return }
        installLegacyAudioPump()
    }

    @discardableResult
    private func installLegacyAudioPump() -> Task<Void, Never> {
        let (stream2, cont2) = AsyncStream<Data>.makeStream()
        audioCont = cont2
        let pump = Task { [weak self] in
            guard let self else { return }
            await self.runLegacyAudioPump(stream2)
        }
        audioPumpTask = pump
        return pump
    }

    private func runLegacyAudioPump(_ stream: AsyncStream<Data>) async {
        do {
            var packetCount = 0
            for await chunk in stream {
                try await sendAudioFrame(chunk, final: false)
                packetCount += 1
            }
            guard !Task.isCancelled else { return }
            asrLogger.info("音频包发送完毕，共 \(packetCount, privacy: .public) 包，发送末尾帧")
            try await sendAudioFrame(Data(), final: true)
            isFinishing = true
        } catch {
            guard !Task.isCancelled else { return }
            terminateConnection(
                .failed(ASRFailure.transport(error)),
                closeCode: .goingAway
            )
        }
    }

    func startLegacyAudioPumpForTesting() -> Task<Void, Never> {
        terminalDelivered = false
        isFinishing = false
        connectionMode = .legacyQueue
        return installLegacyAudioPump()
    }

    var connectionResourcesReleasedForTesting: Bool {
        task == nil
            && audioCont == nil
            && receiveTask == nil
            && audioPumpTask == nil
            && connectionMode == nil
    }

    func startDirectStream() async throws -> AsyncStream<StreamingASRTransportEvent> {
        let events = replaceDirectEventStream()
        do {
            _ = try await openConnection(mode: .direct)
            return events
        } catch {
            directEventsCont?.finish()
            directEventsCont = nil
            throw error
        }
    }

    func replaceDirectEventStream() -> AsyncStream<StreamingASRTransportEvent> {
        directEventsCont?.finish()
        let (events, continuation) = AsyncStream<StreamingASRTransportEvent>.makeStream()
        directEventsCont = continuation
        return events
    }

    private func openConnection(mode: ConnectionMode) async throws -> Bool {
        guard task == nil else { return false }
        guard let url = URL(string: "wss://\(config.host)\(config.path)") else {
            throw ASRError.invalidURL
        }
        asrLogger.info("Starting ASR connection")

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
        terminalDelivered = false
        connectionMode = mode
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
        do {
            try await ws.send(.data(startFrame))
        } catch {
            let failure = ASRFailure.transport(error)
            terminateConnection(.failed(failure), closeCode: .goingAway)
            throw failure
        }
        asrLogger.info("起始帧已发送")
        emit(.state(.streaming))

        // 接收循环
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return true
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
        connectionMode = nil
        emit(.state(.idle))
    }

    /// Direct-stream cancellation is a hard event barrier: it returns only after the receive and
    /// send tasks from this connection can no longer publish transport events.
    func cancelDirectStream() async {
        let receiveTask = receiveTask
        let audioPumpTask = audioPumpTask
        cancel()
        await receiveTask?.value
        await audioPumpTask?.value
        directEventsCont?.finish()
        directEventsCont = nil
        self.receiveTask = nil
        self.audioPumpTask = nil
    }

    func sendDirectAudioFrames(_ frames: [VADPCMFrame]) async throws {
        guard connectionMode == .direct, task != nil, !isFinishing else {
            throw ASRFailure.categorized(.connectionLost)
        }
        var bytes = Data()
        bytes.reserveCapacity(frames.count * VADPCMFrame.byteCount)
        for frame in frames {
            bytes.append(contentsOf: frame.littleEndianBytes)
        }
        do {
            try await sendAudioFrame(bytes, final: false)
        } catch {
            let failure = ASRFailure.transport(error)
            terminateConnection(.failed(failure), closeCode: .goingAway)
            throw failure
        }
    }

    func finishDirectStream() async throws {
        guard connectionMode == .direct, task != nil else {
            throw ASRFailure.categorized(.connectionLost)
        }
        guard !isFinishing else { return }
        isFinishing = true
        do {
            try await sendAudioFrame(Data(), final: true)
        } catch {
            let failure = ASRFailure.transport(error)
            terminateConnection(.failed(failure), closeCode: .goingAway)
            throw failure
        }
    }

    // MARK: - 内部

    private func sendAudioFrame(_ data: Data, final: Bool) async throws {
        if let frameSender {
            try await frameSender(data, final)
            return
        }
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
                    terminateConnection(
                        .failed(ASRFailure.transport(error)),
                        closeCode: .goingAway
                    )
                }
                break
            }
        }
    }

    func handleServerData(_ data: Data) {
        do {
            let frame = try SAUC.parseServerFrame(data)
            switch frame.messageType {
            case .fullServerResponse:
                guard let obj = try? JSONDecoder().decode(
                    ASRResponse.self,
                    from: frame.payload
                ) else {
                    terminateConnection(
                        .failed(.categorized(.protocolFailure)),
                        closeCode: .goingAway
                    )
                    return
                }
                if let text = obj.result?.text, !text.isEmpty {
                    emit(.transcript(text))
                    asrLogger.debug("ASR transcript delta received; characters=\(text.count, privacy: .public)")
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
                    terminateConnection(.finished, closeCode: .normalClosure)
                }
            case .error:
                let (code, _) = try SAUC.parseErrorFrame(data)
                asrLogger.error("ASR provider error; code=\(code, privacy: .public)")
                terminateConnection(
                    .failed(ASRFailure.providerStatus(code)),
                    closeCode: .goingAway
                )
            default:
                break
            }
        } catch {
            terminateConnection(
                .failed(.categorized(.protocolFailure)),
                closeCode: .goingAway
            )
        }
    }

    private func terminateConnection(
        _ outcome: TerminalOutcome,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) {
        guard !terminalDelivered else { return }
        terminalDelivered = true
        isFinishing = true
        switch outcome {
        case .finished:
            emit(.state(.finished))
        case .failed(let failure):
            emit(.state(.failed(failure)))
        }
        directEventsCont?.finish()
        directEventsCont = nil
        audioCont?.finish()
        audioCont = nil
        let receiveTask = receiveTask
        let audioPumpTask = audioPumpTask
        self.receiveTask = nil
        self.audioPumpTask = nil
        receiveTask?.cancel()
        audioPumpTask?.cancel()
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        connectionMode = nil
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
        switch event {
        case .state(.finished):
            directEventsCont?.yield(.finished)
        case .state(.failed(let failure)), .error(let failure):
            directEventsCont?.yield(.failed(failure))
        case .transcript(let text):
            directEventsCont?.yield(.transcript(text))
        case .utterance(let text):
            directEventsCont?.yield(.utterance(text))
        case .state:
            break
        }
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
