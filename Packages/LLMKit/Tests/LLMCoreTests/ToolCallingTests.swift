import XCTest
@testable import LLMCore

final class ToolCallingTests: XCTestCase {

    func testToolDefinitionEncoding() throws {
        let tool = LLMTool(function: .init(
            name: "web_search",
            description: "联网搜索",
            parameters: [
                "type": .string("object"),
                "required": .array([.string("query")])
            ]
        ))
        let data = try JSONEncoder().encode(tool)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "function")
        let fn = try XCTUnwrap(json["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "web_search")
        let params = try XCTUnwrap(fn["parameters"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertEqual((params["required"] as? [String])?.first, "query")
    }

    func testToolCallResponseDecoding() throws {
        let json = """
        {
          "id": "call_abc123",
          "type": "function",
          "function": { "name": "web_search", "arguments": "{\\"query\\":\\"北京天气\\"}" }
        }
        """
        let call = try JSONDecoder().decode(LLMToolCall.self, from: Data(json.utf8))
        XCTAssertEqual(call.id, "call_abc123")
        XCTAssertEqual(call.function.name, "web_search")
        XCTAssertEqual(call.function.arguments, #"{"query":"北京天气"}"#)
    }

    func testMessageWithToolCalls() throws {
        let msg = LLMMessage(role: .assistant, content: nil, toolCalls: [
            .init(id: "c1", type: "function", function: .init(name: "web_search", arguments: "{}"))
        ])
        let data = try JSONEncoder().encode(msg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["content"])
        let calls = try XCTUnwrap(json["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
    }

    func testToolMessageEncoding() throws {
        let msg = LLMMessage(role: .tool, content: "结果", toolCallID: "c1")
        let data = try JSONEncoder().encode(msg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["role"] as? String, "tool")
        XCTAssertEqual(json["tool_call_id"] as? String, "c1")
    }

    func testRequestWithTools() throws {
        let req = LLMChatRequest(model: "deepseek-v4-flash",
                                 messages: [.init(role: .user, content: "hi")],
                                 tools: [.init(function: .init(name: "web_search", description: "s", parameters: [:]))])
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
    }
}
