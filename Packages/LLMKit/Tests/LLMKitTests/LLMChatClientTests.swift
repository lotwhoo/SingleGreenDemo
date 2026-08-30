import XCTest
@testable import LLMKit

final class LLMChatClientTests: XCTestCase {

    func testRequestEncodingSnakeCase() throws {
        let req = LLMChatRequest(
            model: "deepseek-v4-flash",
            messages: [
                .init(role: .system, content: "你是助手"),
                .init(role: .user, content: "你好"),
            ],
            temperature: 0.7,
            maxTokens: 512
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "deepseek-v4-flash")
        XCTAssertEqual(json["max_tokens"] as? Int, 512)
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["content"] as? String, "你好")
    }

    func testResponseDecoding() throws {
        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "index": 0,
              "message": { "role": "assistant", "content": "你好！有什么可以帮你？" },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 15, "completion_tokens": 12, "total_tokens": 27 }
        }
        """
        let obj = try JSONDecoder().decode(LLMChatResponse.self, from: Data(json.utf8))
        XCTAssertEqual(obj.id, "chatcmpl-test")
        XCTAssertEqual(obj.choices.first?.message.role, .assistant)
        XCTAssertEqual(obj.choices.first?.message.content, "你好！有什么可以帮你？")
        XCTAssertEqual(obj.choices.first?.finishReason, "stop")
        XCTAssertEqual(obj.usage?.totalTokens, 27)
    }

    func testErrorResponseDecoding() throws {
        let json = """
        { "error": { "message": "Insufficient Balance", "type": "invalid_request_error", "code": "invalid_request_error" } }
        """
        let obj = try JSONDecoder().decode(LLMErrorResponse.self, from: Data(json.utf8))
        XCTAssertEqual(obj.error?.message, "Insufficient Balance")
    }

    func testConfigDefaults() {
        let config = LLMChatClient.Config(apiKey: "sk-test")
        XCTAssertEqual(config.model, "deepseek-v4-flash")
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.deepseek.com/v1")
        XCTAssertNil(config.thinking)
        XCTAssertNil(config.responseFormat)
    }

    func testSSEChunkDecoding() throws {
        let json = #"{"choices":[{"delta":{"content":"你"}}]}"#
        let chunk = try JSONDecoder().decode(LLMSSEChunk.self, from: Data(json.utf8))
        XCTAssertEqual(chunk.choices.first?.delta?.content, "你")
    }

    func testStreamingRequestEncodesStreamFlag() throws {
        let req = LLMChatRequest(model: "deepseek-v4-flash",
                                 messages: [.init(role: .user, content: "hi")],
                                 stream: true)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testThinkingRequestEncodesDeepSeekFieldsExactly() throws {
        let request = LLMChatRequest(
            model: "reasoning-model",
            messages: [.init(role: .user, content: "hi")],
            stream: true,
            thinking: .enabled(effort: .maximum)
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
        XCTAssertEqual(thinking as NSDictionary, ["type": "enabled"] as NSDictionary)
        XCTAssertEqual(json["reasoning_effort"] as? String, "max")
    }

    func testDisabledThinkingOmitsReasoningEffort() throws {
        let request = LLMChatRequest(
            model: "reasoning-model",
            messages: [.init(role: .user, content: "hi")],
            thinking: .disabled
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(json["reasoning_effort"])
    }

    func testJSONResponseFormatEncodesOpenAICompatibleObject() throws {
        let request = LLMChatRequest(
            model: "deepseek-chat",
            messages: [.init(role: .user, content: "return json")],
            thinking: nil,
            responseFormat: .jsonObject
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            json["response_format"] as? NSDictionary,
            ["type": "json_object"] as NSDictionary
        )
    }
}
