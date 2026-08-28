import Foundation
import Darwin
import VoiceChatCore
import LLMKit

/// ASRCLI：用与 iOS App 完全相同的 Swift ASRClient 直连火山豆包流式语音识别 2.0，
/// 验证端到端链路（URLSessionWebSocketTask 握手/鉴权头、SAUC 帧、gzip、流式推送）。
///
/// 用法（在 Core 目录下）：
///   swift run ASRCLI [wav路径] [--key <API_KEY>]
/// Key 来源：--key > 环境变量 VOLC_API_KEY > 仓库根 .secrets/volc.json > ~/.dsh/volc-api-key
@main
struct ASRCLI {

    static func main() async {
        do {
            try await run()
        } catch {
            print("执行失败（\(coarseReason(for: error).rawValue)）")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        // ---- 参数解析 ----
        var args = CommandLine.arguments.dropFirst().map { $0 }
        var apiKey: String? = nil
        var wavPath: String? = nil
        var llmQuestion: String? = nil
        var deepseekKey: String? = nil
        var searchQuestion: String? = nil
        var llmStream = false
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--key" where !args.isEmpty:
                apiKey = args.removeFirst()
            case "--llm" where !args.isEmpty:
                llmQuestion = args.removeFirst()
            case "--llm-stream" where !args.isEmpty:
                llmQuestion = args.removeFirst()
                llmStream = true
            case "--search" where !args.isEmpty:
                searchQuestion = args.removeFirst()
            case "--deepseek-key" where !args.isEmpty:
                deepseekKey = args.removeFirst()
            default:
                wavPath = a
            }
        }

        // 联网搜索模式：验证 DeepSeek 工具调用 → Bocha → 回答
        if let question = searchQuestion {
            let key = deepseekKey ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
            let dsKey = key.isEmpty ? (try? resolveDeepSeekKey()) ?? "" : key
            guard !dsKey.isEmpty else { throw CLIError.noDeepSeekKey }
            let bochaKey = try resolveBochaKey()
            let client = LLMChatClient(config: LLMChatClient.Config(apiKey: dsKey))
            let searcher = BochaSearchClient(config: BochaSearchClient.Config(apiKey: bochaKey))
            let agent = LLMAgent(transport: client, executor: searcher,
                                 config: .init(systemPrompt: "你是语音助手，用简洁中文回答。"))
            print("提问已接收（\(question.count) 字符）")
            let answer = try await agent.send(question) { _ in
                print("🔍 已触发工具调用")
            }
            print("回答已完成（\(answer.count) 字符）")
            return
        }

        // LLM 模式：验证 DeepSeek 回答链路
        if let question = llmQuestion {
            let key = deepseekKey ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? ""
            let dsKey = key.isEmpty ? (try? resolveDeepSeekKey()) ?? "" : key
            guard !dsKey.isEmpty else {
                throw CLIError.noDeepSeekKey
            }
            let client = LLMChatClient(config: LLMChatClient.Config(apiKey: dsKey))
            let messages = [
                LLMMessage(role: .system, content: "你是一个友好的语音助手，用简洁中文回答。"),
                LLMMessage(role: .user, content: question),
            ]
            print("提问已接收（\(question.count) 字符）")
            if llmStream {
                var characterCount = 0
                for try await delta in client.completeStreaming(messages: messages, temperature: 0.7) {
                    characterCount += delta.count
                }
                print("流式回答已完成（\(characterCount) 字符）")
            } else {
                let reply = try await client.complete(messages: messages, temperature: 0.7)
                print("回答已完成（\(reply.count) 字符）")
            }
            return
        }

        let key = try resolveKey(override: apiKey)
        let wav = try resolveWavPath(wavPath)
        let pcm = try loadPCM16(wav)
        print("音频已载入：\(pcm.count / 2 / 16000)s，\(pcm.count) 字节")

        // ---- 客户端 ----
        let session = ASRSession(config: ASRSession.Config(
            apiKey: key,
            resourceID: ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? "volc.seedasr.sauc.duration"
        ))

        let (doneStream, doneCont) = AsyncStream<Void>.makeStream()
        let eventsTask = Task {
            var finishedCount = 0
            for await event in session.events {
                switch event {
                case .transcript(let text):
                    print("📝 收到转写更新（\(text.count) 字符）")
                case .state(let state):
                    print("⏺ 状态: \(describe(state))")
                    if state == .finished || isFailed(state) {
                        finishedCount += 1
                        doneCont.yield()
                    }
                case .error:
                    print("❌ 识别失败（service_failure）")
                case .utterance(let text):
                    print("✔ 收到定型句（\(text.count) 字符）")
                case .level:
                    break
                }
            }
            return finishedCount
        }

        print("连接并发送起始帧…")
        try await session.startStream()

        // ---- 200ms 分包推送 ----
        let chunkSize = 6400
        var sent = 0
        for i in stride(from: 0, to: pcm.count, by: chunkSize) {
            let end = min(i + chunkSize, pcm.count)
            session.pushAudio(pcm.subdata(in: i..<end))
            sent += 1
            try await Task.sleep(for: .milliseconds(15))
        }
        print("已推送 \(sent) 个音频包，发送末尾帧…")
        await session.finish()

        // ---- 等待终态（20s 超时） ----
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(20))
            doneCont.yield()
        }
        for await _ in doneStream { break }
        timeoutTask.cancel()
        eventsTask.cancel()
        await session.cancel()
        let finishedCount = await eventsTask.value
        // 验证 .finished 事件只触发一次（曾因 setState 双 emit 触发两次）
        print("FINISHED_EVENTS: \(finishedCount)（期望 1）")
        print("完成 ✅")
    }

    // MARK: - 工具

    private enum CLIError: Error {
        case noKey, noWav(String), badWav, noDeepSeekKey, noBochaKey
    }

    private enum CoarseFailureReason: String {
        case configurationMissing = "configuration_missing"
        case invalidInput = "invalid_input"
        case unauthorized
        case networkUnavailable = "network_unavailable"
        case serviceFailure = "service_failure"
    }

    private static func coarseReason(for error: Error) -> CoarseFailureReason {
        switch error {
        case CLIError.noKey, CLIError.noDeepSeekKey, CLIError.noBochaKey:
            return .configurationMissing
        case CLIError.noWav, CLIError.badWav:
            return .invalidInput
        case let error as LLMAPIError where error.statusCode == 401 || error.statusCode == 403:
            return .unauthorized
        case let error as BochaSearchClient.BochaError:
            if case .apiError(let statusCode, _) = error,
               statusCode == 401 || statusCode == 403 {
                return .unauthorized
            }
            return .serviceFailure
        case is URLError:
            return .networkUnavailable
        default:
            return .serviceFailure
        }
    }

    private static func resolveBochaKey() throws -> String {
        if let env = ProcessInfo.processInfo.environment["BOCHA_API_KEY"], !env.isEmpty { return env }
        for p in ["../../.secrets/bocha.json", "../.secrets/bocha.json"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let k = obj["api_key"] as? String, !k.isEmpty {
                return k
            }
        }
        throw CLIError.noBochaKey
    }

    private static func resolveDeepSeekKey() throws -> String {
        for p in ["../../.secrets/deepseek.json", "../.secrets/deepseek.json"] {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let k = obj["api_key"] as? String, !k.isEmpty {
                return k
            }
        }
        throw CLIError.noDeepSeekKey
    }

    private static func describe(_ state: ASRSession.State) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .finalizing: return "finalizing"
        case .finished: return "finished"
        case .failed(let failure): return "failed(\(failure.code.rawValue))"
        }
    }

    private static func isFailed(_ state: ASRSession.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private static func resolveKey(override: String?) throws -> String {
        if let override, !override.isEmpty { return override }
        if let env = ProcessInfo.processInfo.environment["VOLC_API_KEY"], !env.isEmpty { return env }
        for p in [".secrets/volc.json", "../.secrets/volc.json", "../../.secrets/volc.json",
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/volc-api-key").path] {
            if FileManager.default.fileExists(atPath: p) {
                if p.hasSuffix(".json"),
                   let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let k = obj["api_key"] as? String, !k.isEmpty {
                    return k
                }
                if let k = try? String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
                    return k
                }
            }
        }
        throw CLIError.noKey
    }

    private static func resolveWavPath(_ given: String?) throws -> String {
        let candidates = [given, "m0/test_zh.wav", "../m0/test_zh.wav", "../../m0/test_zh.wav"]
            .compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        throw CLIError.noWav(candidates.joined(separator: " / "))
    }

    /// 解析 16bit PCM WAV，返回裸 PCM 字节。
    private static func loadPCM16(_ path: String) throws -> Data {
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        guard raw.count >= 12 else { throw CLIError.badWav }
        let riff = raw.subdata(in: 0..<4)
        let wave = raw.subdata(in: 8..<12)
        guard riff == Data("RIFF".utf8), wave == Data("WAVE".utf8) else {
            throw CLIError.badWav
        }
        var pos = 12
        var pcm: Data?
        while pos + 8 <= raw.count {
            let id = String(data: raw.subdata(in: pos..<pos + 4), encoding: .utf8) ?? ""
            let size = Int(raw.subdata(in: pos + 4..<pos + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            let bodyStart = pos + 8
            guard size <= raw.count - bodyStart else { throw CLIError.badWav }
            let body = raw[bodyStart..<bodyStart + size]
            if id == "data" {
                pcm = Data(body)
            }
            pos += 8 + size + (size & 1)
        }
        guard let pcm else { throw CLIError.badWav }
        return pcm
    }
}
