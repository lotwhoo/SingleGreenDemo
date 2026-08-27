import XCTest
@testable import VoiceChatCore

final class SAUCFrameTests: XCTestCase {

    // Python 生成的完整服务端响应帧: header(0x11 0x91 0x11 0x00) + seq=1 + size + gzip({"result":{"text":"你好，世界",...}})
    private let serverFrameHex =
        "1191110000000001000000751f8b0800bd0a8f6a02ffab562a4a2d2ecd2951b252a8562a49ad0031949eec5df074e9def77b7a9eec98f67c6a8f928e82526949496a51625e726a315041345ea529a96999799925a940e992a2d254a04871496251497c49662e48cc0028909a9702e31a9a1a18d4c6d6d602002e3c798589000000"
    // 末尾帧: header(0x11 0x93 0x11 0x00) + seq=-1 + size + gzip(同 payload)
    private let finalFrameHex =
        "11931100ffffffff000000751f8b0800bd0a8f6a02ffab562a4a2d2ecd2951b252a8562a49ad0031949eec5df074e9def77b7a9eec98f67c6a8f928e82526949496a51625e726a315041345ea529a96999799925a940e992a2d254a04871496251497c49662e48cc0028909a9702e31a9a1a18d4c6d6d602002e3c798589000000"

    func testClientStartFrameLayout() throws {
        // 起始帧: JSON payload，gzip
        let payload = Data("{\"user\":{\"uid\":\"t\"}}".utf8)
        let gz = try XCTUnwrap(Gzip.compress(payload))
        let frame = SAUC.clientFrame(messageType: .fullClientRequest, flags: .noSequence, payload: gz)

        XCTAssertEqual(frame.prefix(4).hexString, "11101100", "header 应为 0x11 0x10 0x11 0x00")
        // payload_size u32 大端
        let sizeBytes = frame[4..<8]
        let size = sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(size), gz.count)
        XCTAssertEqual(frame[8...], gz)
    }

    func testClientAudioFrameLayout() throws {
        let audio = Data((0..<6400).map { UInt8($0 % 256) })
        let gz = try XCTUnwrap(Gzip.compress(audio))
        let frame = SAUC.clientFrame(messageType: .audioOnlyRequest, flags: .noSequence,
                                     serialization: 0, payload: gz)
        XCTAssertEqual(frame.prefix(4).hexString, "11200100", "header 应为 0x11 0x20 0x01 0x00")
    }

    func testParseServerFrame() throws {
        let frame = try SAUC.parseServerFrame(Data(hexString: serverFrameHex)!)
        XCTAssertEqual(frame.messageType, .fullServerResponse)
        XCTAssertEqual(frame.flags, .positiveSequence)
        XCTAssertEqual(frame.sequence, 1)
        let obj = try JSONDecoder().decode(ASRResponse.self, from: frame.payload)
        XCTAssertEqual(obj.result?.text, "你好，世界")
        XCTAssertEqual(obj.result?.utterances?.first?.definite, true)
        XCTAssertEqual(obj.result?.utterances?.first?.startTime, 0)
        XCTAssertEqual(obj.result?.utterances?.first?.endTime, 1500)
    }

    func testParseFinalFrame() throws {
        let frame = try SAUC.parseServerFrame(Data(hexString: finalFrameHex)!)
        XCTAssertEqual(frame.messageType, .fullServerResponse)
        XCTAssertEqual(frame.flags, .finalNegativeSequence)
        XCTAssertEqual(frame.sequence, -1)
    }

    func testParseErrorFrame() throws {
        let raw = makeErrorFrame(message: "hello")
        let (parsedCode, msg) = try SAUC.parseErrorFrame(raw)
        XCTAssertEqual(parsedCode, 45000001)
        XCTAssertEqual(msg, "hello")
    }

    func testGenericParserRecognizesErrorFrame() throws {
        let frame = try SAUC.parseServerFrame(makeErrorFrame(message: "bad key"))

        XCTAssertEqual(frame.messageType, .error)
        XCTAssertEqual(frame.flags, .noSequence)
        XCTAssertNil(frame.sequence)
    }

    func testTruncatedErrorMessageIsRejected() {
        var raw = makeErrorFrame(message: "hello")
        raw.removeLast(2)

        XCTAssertThrowsError(try SAUC.parseErrorFrame(raw)) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidPayloadSize)
        }
        XCTAssertThrowsError(try SAUC.parseServerFrame(raw)) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidPayloadSize)
        }
    }

    func testInvalidHeaderFieldsAreRejected() {
        XCTAssertThrowsError(try SAUC.parseServerFrame(Data([0x21, 0x90, 0, 0, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidVersion)
        }
        XCTAssertThrowsError(try SAUC.parseServerFrame(Data([0x11, 0xE0, 0, 0, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidMessageType(0x0E))
        }
        XCTAssertThrowsError(try SAUC.parseServerFrame(Data([0x11, 0x9F, 0, 0, 0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidFlags(0x0F))
        }
    }

    func testDeclaredPayloadLargerThanFrameIsRejected() {
        let raw = Data([0x11, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x41])

        XCTAssertThrowsError(try SAUC.parseServerFrame(raw)) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidPayloadSize)
        }
    }

    func testInvalidGzipPayloadIsRejected() {
        let raw = Data([0x11, 0x90, 0x01, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03])

        XCTAssertThrowsError(try SAUC.parseServerFrame(raw)) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .invalidPayloadSize)
        }
    }

    func testParseTooShort() {
        XCTAssertThrowsError(try SAUC.parseServerFrame(Data([0x11, 0x91]))) { error in
            XCTAssertEqual(error as? SAUC.ParseError, .tooShort)
        }
    }

    private func makeErrorFrame(message: String) -> Data {
        var raw = Data([0x11, 0xF0, 0x00, 0x00])
        var code = UInt32(45000001).bigEndian
        withUnsafeBytes(of: &code) { raw.append(contentsOf: $0) }
        let messageData = Data(message.utf8)
        var size = UInt32(messageData.count).bigEndian
        withUnsafeBytes(of: &size) { raw.append(contentsOf: $0) }
        raw.append(messageData)
        return raw
    }
}
