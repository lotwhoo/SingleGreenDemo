import XCTest
@testable import VoiceChatCore

final class ASRModelsTests: XCTestCase {

    func testDecodeResponse() throws {
        let json = """
        {
          "audio_info": { "duration": 3696 },
          "result": {
            "text": "这是一句识别结果",
            "utterances": [
              {
                "text": "这是一句识别结果",
                "definite": true,
                "start_time": 0,
                "end_time": 1705,
                "words": [
                  { "text": "这是", "start_time": 0, "end_time": 400, "conf": 0.98 }
                ]
              }
            ]
          }
        }
        """
        let obj = try JSONDecoder().decode(ASRResponse.self, from: Data(json.utf8))
        XCTAssertEqual(obj.audioInfo?.duration, 3696)
        XCTAssertEqual(obj.result?.text, "这是一句识别结果")
        let utt = try XCTUnwrap(obj.result?.utterances?.first)
        XCTAssertEqual(utt.definite, true)
        XCTAssertEqual(utt.words?.first?.conf, 0.98)
    }

    func testEncodeStartRequestSnakeCase() throws {
        let req = ASRStartRequest(
            user: .init(uid: "ios-test"),
            audio: .init(language: "zh-CN"),
            request: .init(enableITN: true, enablePunc: true, showUtterances: true)
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requestObj = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(requestObj["model_name"] as? String, "bigmodel")
        XCTAssertEqual(requestObj["enable_itn"] as? Bool, true)
        XCTAssertEqual(requestObj["result_type"] as? String, "single")
        XCTAssertEqual(requestObj["ssd_version"] as? String, "200")
        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        XCTAssertEqual(audio["rate"] as? Int, 16000)
        XCTAssertEqual(audio["language"] as? String, "zh-CN")
    }

    func testEncodeHotwordCorpusAsEmbeddedJSONString() throws {
        let context = #"{"hotwords":[{"word":"VoiceChat"},{"word":"豆包"}]}"#
        let request = ASRStartRequest(
            user: .init(uid: "ios-test"),
            audio: .init(),
            request: .init(corpus: .init(context: context))
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requestObject = try XCTUnwrap(json["request"] as? [String: Any])
        let corpus = try XCTUnwrap(requestObject["corpus"] as? [String: Any])
        XCTAssertEqual(corpus["context"] as? String, context)
    }
}
