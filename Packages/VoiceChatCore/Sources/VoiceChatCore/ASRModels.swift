import Foundation

/// ASR 起始请求（全量客户端请求的 JSON payload）。
public struct ASRStartRequest: Codable, Sendable, Equatable {
    public var user: User
    public var audio: Audio
    public var request: Request

    public struct User: Codable, Sendable, Equatable {
        public var uid: String
        public init(uid: String) { self.uid = uid }
    }

    public struct Audio: Codable, Sendable, Equatable {
        public var format: String   // "pcm"
        public var rate: Int        // 16000
        public var bits: Int        // 16
        public var channel: Int     // 1
        public var language: String // "zh-CN"
        public init(format: String = "pcm", rate: Int = 16000, bits: Int = 16,
                    channel: Int = 1, language: String = "zh-CN") {
            self.format = format; self.rate = rate; self.bits = bits
            self.channel = channel; self.language = language
        }
    }

    public struct Request: Codable, Sendable, Equatable {
        public var modelName: String
        public var enableITN: Bool
        public var enablePunc: Bool
        public var enableDDC: Bool
        public var showUtterances: Bool
        public var resultType: String   // "single" 增量 / "full" 整句
        public var ssdVersion: String   // "200" 大模型 SSD
        public var corpus: Corpus?      // 热词/纠错/上下文

        public init(modelName: String = "bigmodel", enableITN: Bool = true,
                    enablePunc: Bool = true, enableDDC: Bool = false,
                    showUtterances: Bool = true, resultType: String = "single",
                    ssdVersion: String = "200", corpus: Corpus? = nil) {
            self.modelName = modelName; self.enableITN = enableITN
            self.enablePunc = enablePunc; self.enableDDC = enableDDC
            self.showUtterances = showUtterances; self.resultType = resultType
            self.ssdVersion = ssdVersion; self.corpus = corpus
        }

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case enableITN = "enable_itn"
            case enablePunc = "enable_punc"
            case enableDDC = "enable_ddc"
            case showUtterances = "show_utterances"
            case resultType = "result_type"
            case ssdVersion = "ssd_version"
            case corpus
        }
    }

    /// 热词/上下文配置。`context` 为 JSON 字符串，
    /// 例如 {"hotwords":[{"word":"豆包"}]}。
    public struct Corpus: Codable, Sendable, Equatable {
        public var context: String?
        public init(context: String?) { self.context = context }
    }

    public init(user: User, audio: Audio, request: Request) {
        self.user = user; self.audio = audio; self.request = request
    }
}

/// ASR 服务端响应。
public struct ASRResponse: Codable, Sendable, Equatable {
    public var audioInfo: AudioInfo?
    public var result: Result?

    enum CodingKeys: String, CodingKey {
        case audioInfo = "audio_info"
        case result
    }

    public struct AudioInfo: Codable, Sendable, Equatable {
        public var duration: Int?
        enum CodingKeys: String, CodingKey { case duration }
    }

    public struct Result: Codable, Sendable, Equatable {
        public var text: String?
        public var utterances: [Utterance]?
    }

    public struct Utterance: Codable, Sendable, Equatable {
        public var text: String?
        public var definite: Bool?
        public var startTime: Int?
        public var endTime: Int?
        public var words: [Word]?

        enum CodingKeys: String, CodingKey {
            case text, definite
            case startTime = "start_time"
            case endTime = "end_time"
            case words
        }
    }

    public struct Word: Codable, Sendable, Equatable {
        public var text: String?
        public var startTime: Int?
        public var endTime: Int?
        public var conf: Double?

        enum CodingKeys: String, CodingKey {
            case text, conf
            case startTime = "start_time"
            case endTime = "end_time"
        }
    }
}
