import Foundation
import zlib

/// gzip 压缩/解压（RFC 1952），基于系统 zlib。
/// 服务端要求每帧载荷为独立 gzip 流，不能用 Apple Compression 框架（其只产出 zlib/raw 流）。
///
/// 注意：zlib 的 `next_in`/`avail_in` 必须在整个 deflate/inflate 生命周期内有效，
/// 因此所有操作都放在 `data.withUnsafeBytes` 单个闭包内完成（不能把指针存到闭包外再用）。
public enum Gzip {

    /// 压缩为 gzip 格式。空数据也产出合法的空 gzip 流（服务端末尾帧需要）。
    public static func compress(_ data: Data) -> Data? {
        var stream = z_stream()
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            let initResult = versionPointer { ver in
                deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                              Z_DEFAULT_STRATEGY, ver, Int32(MemoryLayout<z_stream>.size))
            }
            guard initResult == Z_OK else { return nil }
            defer { deflateEnd(&stream) }

            let bound = Int(deflateBound(&stream, uLong(data.count)))
            let outPtr = UnsafeMutablePointer<Bytef>.allocate(capacity: bound)
            defer { outPtr.deallocate() }

            stream.next_out = outPtr
            stream.avail_out = uInt(bound)
            let result = deflate(&stream, Z_FINISH)
            guard result == Z_STREAM_END else { return nil }
            return Data(bytes: outPtr, count: Int(stream.total_out))
        }
    }

    /// 解压 gzip（自动识别 gzip/zlib 头）。
    public static func decompress(_ data: Data) -> Data? {
        var stream = z_stream()
        var out = Data()
        let ok = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)

            let initResult = versionPointer { ver in
                inflateInit2_(&stream, 15 + 32, ver, Int32(MemoryLayout<z_stream>.size))
            }
            guard initResult == Z_OK else { return false }
            defer { inflateEnd(&stream) }

            var buffer = [Bytef](repeating: 0, count: 64 * 1024)
            var result: Int32 = Z_OK
            var finished = false
            repeat {
                let capacity = buffer.count
                let produced = buffer.withUnsafeMutableBytes { (mraw: UnsafeMutableRawBufferPointer) -> Int in
                    stream.next_out = mraw.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    result = inflate(&stream, Z_NO_FLUSH)
                    return capacity - Int(stream.avail_out)
                }
                if produced > 0 {
                    out.append(buffer, count: produced)
                }
                if result == Z_STREAM_END {
                    finished = true
                    break
                }
            } while result == Z_OK
            return finished
        }
        return ok ? out : nil
    }

    /// 向 C 函数安全地传递 zlib 版本字符串。
    private static func versionPointer<T>(_ body: (UnsafePointer<CChar>) -> T) -> T {
        let version = String(cString: zlibVersion())
        return version.withCString(body)
    }
}
