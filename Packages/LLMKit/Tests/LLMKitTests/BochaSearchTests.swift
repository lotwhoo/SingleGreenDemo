import XCTest
@testable import LLMKit

final class BochaSearchTests: XCTestCase {

    func testResponseDecoding() throws {
        let json = """
        {
          "code": 200,
          "data": {
            "webPages": {
              "value": [
                { "name": "北京天气-天气预报", "url": "https://example.com/beijing",
                  "summary": "北京今天晴，最高 25 度，微风。", "site_name": "天气网" },
                { "name": "另一条结果", "url": "https://example.com/2", "summary": "北京明天多云。" }
              ]
            }
          }
        }
        """
        let obj = try JSONDecoder().decode(BochaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(obj.code, 200)
        let pages = try XCTUnwrap(obj.data?.webPages?.value)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].name, "北京天气-天气预报")
        XCTAssertEqual(pages[0].summary, "北京今天晴，最高 25 度，微风。")
        XCTAssertEqual(pages[0].siteName, "天气网")
    }

    func testEmptyResultDecoding() throws {
        let json = #"{"code": 200, "data": { "webPages": { "value": [] } } }"#
        let obj = try JSONDecoder().decode(BochaResponse.self, from: Data(json.utf8))
        XCTAssertTrue(obj.data?.webPages?.value?.isEmpty ?? false)
    }

    func testToolDefinitions() {
        let client = BochaSearchClient(config: .init(apiKey: "test"))
        XCTAssertEqual(client.toolDefinitions.count, 1)
        XCTAssertEqual(client.toolDefinitions.first?.function.name, "web_search")
    }

    func testUnsupportedToolIsRejectedBeforeNetworkRequest() async {
        let client = BochaSearchClient(config: .init(apiKey: "test"))
        let call = LLMToolCall(id: "c", type: "function",
                               function: .init(name: "other", arguments: #"{"query":"天气"}"#))

        do {
            _ = try await client.execute(call)
            XCTFail("不支持的工具应抛错")
        } catch let error as BochaSearchClient.BochaError {
            guard case .unsupportedTool("other") = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testBlankQueryIsRejectedBeforeNetworkRequest() async {
        let client = BochaSearchClient(config: .init(apiKey: "test"))
        let call = LLMToolCall(id: "c", type: "function",
                               function: .init(name: "web_search", arguments: #"{"query":"  \n"}"#))

        do {
            _ = try await client.execute(call)
            XCTFail("空 query 应抛错")
        } catch let error as BochaSearchClient.BochaError {
            guard case .missingQuery = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    /// 通过 MockURLProtocol 验证搜索请求与结果格式化。
    func testSearchRequestAndFormat() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            // 验证请求
            XCTAssertEqual(request.url?.absoluteString, "https://api.bochaai.com/v1/web-search")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-bocha-test")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["query"] as? String, "北京天气")
            XCTAssertEqual(json["summary"] as? Bool, true)
            let resp = """
            { "code": 200, "data": { "webPages": { "value": [
              { "name": "北京天气", "url": "https://t.cn/1", "summary": "晴 25 度" }
            ] } } }
            """
            return (HTTPURLResponse(url: URL(string: "https://api.bochaai.com/v1/web-search")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(resp.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let client = BochaSearchClient(config: .init(apiKey: "sk-bocha-test"),
                                       session: URLSession(configuration: config))
        let call = LLMToolCall(id: "c1", type: "function",
                               function: .init(name: "web_search",
                                               arguments: #"{"query":"北京天气"}"#))
        let result = try await client.execute(call)
        XCTAssertTrue(result.contains("北京天气"))
        XCTAssertTrue(result.contains("晴 25 度"))
    }

    func testHTTP200BusinessErrorIsRejected() async {
        let client = makeClient(response: #"{"code":401,"message":"invalid key"}"#)
        defer { MockURLProtocol.requestHandler = nil }
        let call = LLMToolCall(id: "c", type: "function",
                               function: .init(name: "web_search", arguments: #"{"query":"天气"}"#))

        do {
            _ = try await client.execute(call)
            XCTFail("业务错误码应抛错")
        } catch let error as BochaSearchClient.BochaError {
            guard case .apiError(let code, let message) = error else {
                return XCTFail("错误类型不对: \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(message, "invalid key")
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    func testMalformedSuccessResponseIsRejected() async {
        let client = makeClient(response: "not-json")
        defer { MockURLProtocol.requestHandler = nil }
        let call = LLMToolCall(id: "c", type: "function",
                               function: .init(name: "web_search", arguments: #"{"query":"天气"}"#))

        do {
            _ = try await client.execute(call)
            XCTFail("畸形响应应抛错")
        } catch let error as BochaSearchClient.BochaError {
            guard case .invalidResponse = error else { return XCTFail("错误类型不对: \(error)") }
        } catch {
            XCTFail("错误类型不对: \(error)")
        }
    }

    private func makeClient(response body: String) -> BochaSearchClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.bochaai.com/v1/web-search")!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        return BochaSearchClient(config: .init(apiKey: "test"),
                                 session: URLSession(configuration: config))
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
