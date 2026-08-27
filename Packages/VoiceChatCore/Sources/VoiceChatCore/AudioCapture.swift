import AVFoundation
#if os(iOS)
import UIKit
#endif

/// 麦克风采集：AVAudioEngine 输入 → AVAudioConverter → 16kHz / 16bit / 单声道 PCM
/// 按 200ms（6400 字节）切包回调。
public final class AudioCapture {

    public enum CaptureError: Error, LocalizedError {
        case noInput
        case converterFailed
        case engineFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noInput: return "没有可用的音频输入设备"
            case .converterFailed: return "音频格式转换器创建失败"
            case .engineFailed(let msg): return "录音引擎启动失败: \(msg)"
            }
        }
    }

    public static let sampleRate = 16000.0
    public static let chunkBytes = 6400 // 200ms @ 16kHz/16bit/mono

    private let engine = AVAudioEngine()
    private var pending = Data()
    private var onChunk: ((Data) -> Void)?
    private var onLevel: ((Float) -> Void)?
    private(set) public var isRunning = false

    public init() {}

    /// 开始录音。chunkHandler 在音频线程回调；levelHandler 返回 0~1 峰值电平。
    public func start(chunkHandler: @escaping (Data) -> Void,
                      levelHandler: ((Float) -> Void)? = nil) throws {
        guard !isRunning else { return }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw CaptureError.noInput }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw CaptureError.converterFailed
        }

        onChunk = chunkHandler
        onLevel = levelHandler
        pending.removeAll()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, target: target)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        isRunning = true
    }

    /// 停止录音。flushRemainder 为 true 时把不足 200ms 的尾部数据也发出去。
    public func stop(flushRemainder: Bool = true) {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        if flushRemainder, !pending.isEmpty, let onChunk {
            onChunk(pending)
            pending.removeAll()
        }
        isRunning = false
    }

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         target: AVAudioFormat) {
        // 电平（取输入缓冲峰值）
        if let onLevel, let channels = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            if frames > 0 {
                for i in 0..<frames {
                    peak = max(peak, abs(channels[0][i]))
                }
                onLevel(min(peak, 1))
            }
        }

        guard let out = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(
                Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 128
        ) else { return }

        var consumed = false
        var convertError: NSError?
        let status = converter.convert(to: out, error: &convertError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let int16Data = out.int16ChannelData else { return }

        let count = Int(out.frameLength) * 2
        guard count > 0 else { return }
        int16Data[0].withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            pending.append(bytes, count: count)
        }

        while pending.count >= Self.chunkBytes {
            let chunk = Data(pending.prefix(Self.chunkBytes))
            pending.removeFirst(Self.chunkBytes)
            onChunk?(chunk)
        }
    }
}
