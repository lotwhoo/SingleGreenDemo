import Foundation
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

    static func main() async throws {
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
            print("提问: \(question)")
            let answer = try await agent.send(question) { toolName in
                print("🔍 触发工具: \(toolName)")
            }
            print("回答: \(answer)")
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
            print("提问: \(question)")
            if llmStream {
                print("回答(流式): ", terminator: "")
                for try await delta in client.completeStreaming(messages: messages, temperature: 0.7) {
                    print(delta, terminator: "")
                    fflush(stdout)
                }
                print()
            } else {
                let reply = try await client.complete(messages: messages, temperature: 0.7)
                print("回答: \(reply)")
            }
            return
        }

        let key = try resolveKey(override: apiKey)
        let wav = try resolveWavPath(wavPath)
        let pcm = try loadPCM16(wav)
        print("音频: \(wav)  \(pcm.count / 2 / 16000)s  \(pcm.count) 字节")

        // ---- 客户端 ----
        let session = ASRSession(config: ASRSession.Config(
            apiKey: key,
            resourceID: ProcessInfo.processInfo.environment["VOLC_RESOURCE_ID"] ?? "volc.seedasr.sauc.duration"
        ))

        let (doneStream, doneCont) = AsyncStream<Void>.makeStream()
        var finishedCount = 0
        let eventsTask = Task {
            for await event in session.events {
                switch event {
                case .transcript(let text):
                    print("📝 \(text)")
                case .state(let state):
                    print("⏺ 状态: \(describe(state))")
                    if state == .finished || isFailed(state) {
                        finishedCount += 1
                        doneCont.yield()
                    }
                case .error(let message):
                    print("❌ 错误: \(message)")
                case .utterance(let text):
                    print("✔ 定型句: \(text)")
                case .level:
                    break
                }
            }
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
        // 验证 .finished 事件只触发一次（曾因 setState 双 emit 触发两次）
        print("FINISHED_EVENTS: \(finishedCount)（期望 1）")
        print("完成 ✅")
    }

    // MARK: - 工具

    private enum CLIError: Error, CustomStringConvertible {
        case noKey, noWav(String), badWav, noDeepSeekKey, noBochaKey

        var description: String {
            switch self {
            case .noKey: return "未找到 API Key（--key / VOLC_API_KEY / .secrets/volc.json / ~/.dsh/volc-api-key）"
            case .noWav(let p): return "找不到 wav 文件: \(p)"
            case .badWav: return "不是有效的 16bit PCM WAV"
            case .noDeepSeekKey: return "未找到 DeepSeek Key（--deepseek-key / DEEPSEEK_API_KEY）"
            case .noBochaKey: return "未找到博查 Key（BOCHA_API_KEY / .secrets/bocha.json）"
            }
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
        case .failed(let msg): return "failed(\(msg))"
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
            let body = raw[pos + 8..<pos + 8 + size]
            if id == "data" {
                pcm = Data(body)
            }
            pos += 8 + size + (size & 1)
        }
        guard let pcm else { throw CLIError.badWav }
        return pcm
    }
}
