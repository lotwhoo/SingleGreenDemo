import Foundation

/// SAUC 二进制帧协议（火山引擎流式语音识别大模型 / 豆包 ASR 2.0）。
/// 参考官方协议：4 字节头 + 可选序号 + payload_size(u32 大端) + payload。
public enum SAUCMessageType: UInt8, Sendable, Equatable {
    case fullClientRequest = 0b0001    // 全量客户端请求（起始帧）
    case audioOnlyRequest = 0b0010     // 仅音频请求
    case fullServerResponse = 0b1001   // 全量服务端响应
    case error = 0b1111                // 错误响应
}

public enum SAUCFlags: UInt8, Sendable, Equatable {
    case noSequence = 0b0000           // 无序号
    case positiveSequence = 0b0001     // 正序号在后
    case finalNoSequence = 0b0010      // 末尾包，无序号
    case finalNegativeSequence = 0b0011 // 末尾包，负序号在后
}

public enum SAUC {
    public static let protocolVersion: UInt8 = 0b0001
    public static let headerSize: UInt8 = 0b0001
    public static let serializationJSON: UInt8 = 0b0001
    public static let compressionGzip: UInt8 = 0b0001

    public struct ServerFrame: Sendable {
        public let messageType: SAUCMessageType
        public let flags: SAUCFlags
        public let sequence: Int32?
        public let payload: Data
    }

    public enum ParseError: Error, Sendable, Equatable {
        case tooShort
        case invalidVersion
        case invalidMessageType(UInt8)
        case invalidFlags(UInt8)
        case invalidPayloadSize
    }

    /// 构造客户端帧（起始帧/音频帧）：header + payload_size(u32 大端) + payload。
    public static func clientFrame(
        messageType: SAUCMessageType,
        flags: SAUCFlags,
        serialization: UInt8 = serializationJSON,
        compression: UInt8 = compressionGzip,
        payload: Data
    ) -> Data {
        var out = Data()
        out.append((protocolVersion << 4) | headerSize)
        out.append((messageType.rawValue << 4) | flags.rawValue)
        out.append((serialization << 4) | compression)
        out.append(0)
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// 解析服务端帧：header + (sequence i32)? + payload_size(u32) + payload。
    public static func parseServerFrame(_ data: Data) throws -> ServerFrame {
        guard data.count >= 8 else { throw ParseError.tooShort }
        var d = data
        let b0 = d[0], b1 = d[1], b2 = d[2]
        guard b0 >> 4 == protocolVersion, b0 & 0x0F == headerSize else { throw ParseError.invalidVersion }
        let rawType = b1 >> 4
        let rawFlags = b1 & 0x0F
        guard let mt = SAUCMessageType(rawValue: rawType) else { throw ParseError.invalidMessageType(rawType) }
        guard let fl = SAUCFlags(rawValue: rawFlags) else { throw ParseError.invalidFlags(rawFlags) }
        let compression = b2 & 0x0F
        d.removeFirst(4)

        // 错误帧使用 error_code + msg_size + msg，不是普通 payload_size 布局。
        // 先验证完整性并返回类型，调用方再用 parseErrorFrame 提取错误详情。
        if mt == .error {
            guard d.count >= 8 else { throw ParseError.tooShort }
            let msgSize = Int(d.dropFirst(4).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            })
            guard d.count >= 8 + msgSize else { throw ParseError.invalidPayloadSize }
            return ServerFrame(messageType: mt, flags: fl, sequence: nil, payload: Data(d.prefix(8 + msgSize)))
        }

        var sequence: Int32?
        if fl == .positiveSequence || fl == .finalNegativeSequence {
            guard d.count >= 4 else { throw ParseError.tooShort }
            sequence = d.withUnsafeBytes { $0.loadUnaligned(as: Int32.self).bigEndian }
            d.removeFirst(4)
        }
        guard d.count >= 4 else { throw ParseError.tooShort }
        let payloadSize = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        d.removeFirst(4)
        guard d.count >= payloadSize else { throw ParseError.invalidPayloadSize }

        var payload = d.prefix(payloadSize)
        if compression == compressionGzip && !payload.isEmpty {
            guard let inflated = Gzip.decompress(Data(payload)) else { throw ParseError.invalidPayloadSize }
            payload = inflated
        }
        return ServerFrame(messageType: mt, flags: fl, sequence: sequence, payload: Data(payload))
    }

    /// 解析错误帧：header + error_code(u32) + msg_size(u32) + msg。
    public static func parseErrorFrame(_ data: Data) throws -> (code: UInt32, message: String) {
        guard data.count >= 12 else { throw ParseError.tooShort }
        var d = data.dropFirst(4)
        let code = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        d = d.dropFirst(4)
        let msgSize = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        d = d.dropFirst(4)
        guard d.count >= msgSize else { throw ParseError.invalidPayloadSize }
        let msg = String(data: d.prefix(msgSize), encoding: .utf8) ?? ""
        return (code, msg)
    }
}
