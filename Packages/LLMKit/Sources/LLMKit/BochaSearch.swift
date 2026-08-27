import Foundation

/// 博查（Bocha AI）联网搜索执行器。
/// 实现 `LLMToolExecutor`，供 LLMAgent 在模型请求 web_search 时执行真实搜索。
/// 文档：https://bocha-ai.feishu.cn/wiki/HmtOw1z6vik14Fkdu5uc9VaInBb
public struct BochaSearchClient: LLMToolExecutor {

    public struct Config: Sendable, Equatable {
        public var apiKey: String
        public var count: Int
        /// 时效过滤：oneDay / oneWeek / oneMonth / oneYear / noLimit
        public var freshness: String?
        public var baseURL: URL

        public init(apiKey: String,
                    count: Int = 5,
                    freshness: String? = nil,
                    baseURL: URL = URL(string: "https://api.bochaai.com/v1")!) {
            self.apiKey = apiKey
            self.count = count
            self.freshness = freshness
            self.baseURL = baseURL
        }
    }

    public enum BochaError: Error, LocalizedError, Sendable {
        case unsupportedTool(String)
        case missingQuery
        case invalidResponse
        case apiError(statusCode: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedTool(let name): return "不支持的搜索工具: \(name)"
            case .missingQuery: return "搜索参数缺少 query"
            case .invalidResponse: return "搜索服务返回无效响应"
            case .apiError(let code, let msg): return "搜索 API 错误 (\(code)): \(msg)"
            }
        }
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - LLMToolExecutor

    public var toolDefinitions: [LLMTool] {
        [LLMTool(function: LLMTool.Function(
            name: "web_search",
            description: "当用户询问需要最新、实时或外部世界信息的问题（如天气、新闻、股价、赛事、热点事件、未知事实）时，调用此工具进行联网搜索获取答案。",
            parameters: [
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("搜索关键词，简洁明确，中文优先")
                    ])
                ]),
                "required": .array([.string("query")])
            ]
        ))]
    }

    public func execute(_ call: LLMToolCall) async throws -> String {
        guard call.function.name == "web_search" else {
            throw BochaError.unsupportedTool(call.function.name)
        }
        let query = try parseQuery(from: call.function.arguments)
        return try await search(query)
    }

    // MARK: - 搜索

    private func search(_ query: String) async throws -> String {
        let url = config.baseURL.appendingPathComponent("web-search")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["query": query, "count": config.count, "summary": true]
        if let freshness = config.freshness {
            body["freshness"] = freshness
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BochaError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BochaError.apiError(statusCode: http.statusCode, message: msg)
        }

        guard let result = try? JSONDecoder().decode(BochaResponse.self, from: data) else {
            throw BochaError.invalidResponse
        }
        if let code = result.code, code != 200 {
            throw BochaError.apiError(statusCode: code, message: result.message ?? "未知错误")
        }
        let pages = result.data?.webPages?.value ?? []
        var lines = ["联网搜索结果（来自 \(pages.count) 个网页）："]
        for page in pages {
            lines.append("- [\(page.name ?? "无标题")] \(page.url ?? "")")
            if let summary = page.summary, !summary.isEmpty {
                lines.append("  \(summary)")
            }
        }
        if pages.isEmpty {
            lines.append("（未找到相关结果）")
        }
        return lines.joined(separator: "\n")
    }

    /// 解析工具调用参数 JSON 中的 query。
    private func parseQuery(from arguments: String) throws -> String {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawQuery = obj["query"] as? String else {
            throw BochaError.missingQuery
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw BochaError.missingQuery }
        return query
    }
}

// MARK: - Bocha 响应模型

public struct BochaResponse: Codable, Sendable {
    public struct Data: Codable, Sendable {
        /// webPages 是对象，结果数组在 `value` 字段（实测确认）。
        public struct WebPages: Codable, Sendable {
            public var value: [WebPage]?
        }

        public struct WebPage: Codable, Sendable {
            public var name: String?
            public var url: String?
            public var summary: String?
            public var siteName: String?

            enum CodingKeys: String, CodingKey {
                case name, url, summary
                case siteName = "site_name"
            }
        }

        public var webPages: WebPages?
    }

    public var code: Int?
    public var message: String?
    public var data: Data?
}
