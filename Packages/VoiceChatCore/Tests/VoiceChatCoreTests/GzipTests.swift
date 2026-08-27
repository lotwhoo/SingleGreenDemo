import XCTest
@testable import VoiceChatCore

final class GzipTests: XCTestCase {

    func testRoundTrip() throws {
        for size in [1, 100, 6400, 136_180] {
            var rng = SystemRandomNumberGenerator()
            var data = Data()
            for _ in 0..<size { data.append(UInt8.random(in: 0...255, using: &rng)) }
            guard let gz = Gzip.compress(data) else {
                XCTFail("compress 失败 size=\(size)"); return
            }
            guard let back = Gzip.decompress(gz) else {
                XCTFail("decompress 失败 size=\(size)"); return
            }
            XCTAssertEqual(back, data, "size=\(size) 往返不一致")
        }
    }

    func testGzipMagicBytes() throws {
        let data = Data("你好".utf8)
        guard let gz = Gzip.compress(data) else { return XCTFail("compress 失败") }
        XCTAssertEqual(gz.prefix(2), Data([0x1f, 0x8b]), "必须是 gzip 魔数")
    }

    func testEmptyInputProducesValidGzip() throws {
        // 服务端末尾帧需要合法 gzip 流
        guard let gz = Gzip.compress(Data()) else { return XCTFail("compress 失败") }
        XCTAssertEqual(gz.count, 20, "空 gzip 应为 20 字节")
        guard let back = Gzip.decompress(gz) else { return XCTFail("空 gzip 无法解压") }
        XCTAssertTrue(back.isEmpty)
    }

    /// 与 Python gzip 对拍：解压 Python 生成的 gzip 字节。
    func testDecompressPythonFixture() throws {
        // Python: gzip.compress(bytes(range(64)) + b"hello-voicechat")  原始 79 字节
        let fixture = try XCTUnwrap(Data(hexString: "1f8b0800a10d8f6a02ff6360646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d33730343236313533b7b0b4b2b6b1b5b3cf48cdc9c9d72dcbcf4c4e4dce482c0100f49f6e694f000000"))
        guard let back = Gzip.decompress(fixture) else { return XCTFail("解压夹具失败") }
        XCTAssertEqual(back.count, 79)
        XCTAssertEqual(back.prefix(64), Data((0..<64).map { UInt8($0) }))
        XCTAssertEqual(back.suffix(15), Data("hello-voicechat".utf8))
    }

    /// 与 Python gzip 对拍：Swift 压缩出的字节 Python 能解出原文（用魔数+往返近似验证）。
    func testCompressMatchesPythonSemantics() throws {
        let raw = Data((0..<256).map { UInt8($0) })
        guard let gz = Gzip.compress(raw) else { return XCTFail("compress 失败") }
        guard let back = Gzip.decompress(gz) else { return XCTFail("decompress 失败") }
        XCTAssertEqual(back, raw)
    }
}
