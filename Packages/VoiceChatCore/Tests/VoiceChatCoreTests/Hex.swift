import Foundation

extension Data {
    /// 从十六进制字符串构造 Data（测试夹具用）。
    init?(hexString: String) {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
        guard clean.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
