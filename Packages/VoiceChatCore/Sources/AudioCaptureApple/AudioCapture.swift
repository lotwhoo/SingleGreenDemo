import AVFoundation
import ASRDomain
import os

/// 麦克风采集：AVAudioEngine 输入 → AVAudioConverter → 16kHz / 16bit / 单声道 PCM
/// Legacy callers receive 200 ms chunks by default. Local VAD callers can request exact 20 ms
/// frames without changing the converter or duplicating capture code.
public final class AudioCapture {

    public typealias AudioSystemEvent = ASRAudioSystemEvent

    public enum CaptureError: Error, LocalizedError, Equatable, Sendable {
        case noInput
        case converterFailed
        case engineFailed

        public var errorDescription: String? {
            switch self {
            case .noInput: return "没有可用的音频输入设备"
            case .converterFailed: return "音频格式转换器创建失败"
            case .engineFailed: return "录音引擎启动失败"
            }
        }
    }

    /// Stable diagnostic categories intentionally omit framework error text and recording data.
    public enum ConversionFailure: Sendable, Equatable {
        case inputSnapshotUnavailable
        case inputReconstructionFailed
        case converterError
        case outputUnavailable
    }

    public enum Diagnostic: Sendable, Equatable {
        case conversionFailed(ConversionFailure)
        case audioSystemEvent(AudioSystemEvent)
    }

    public static let sampleRate = 16000.0
    public static let vadFrameBytes = 640 // 20ms @ 16kHz/16bit/mono
    public static let chunkBytes = 6400 // 200ms @ 16kHz/16bit/mono

    private let engine = AVAudioEngine()
    private let runState: AudioCaptureRunState
    private let diagnosticHandler: (@Sendable (Diagnostic) -> Void)?
    private let runDiagnosticHandler: (@Sendable (UInt64, Diagnostic) -> Void)?
    private let audioSessionLifecycle: AudioSessionActivationLifecycle
    private let audioSystemEventBridge: AudioCaptureAudioSystemEventBridge
    private let graphPreparation: any AudioCaptureGraphPreparing
    /// Serializes start/stop graph mutation. Audio callbacks never take this lock; they use
    /// `AudioCaptureRunState`, so the real-time callback cannot deadlock lifecycle teardown.
    private let lifecycleOperations = NSLock()

    public var isRunning: Bool { runState.isRunning }

    deinit {
        stop(flushRemainder: false)
    }

    public init(diagnosticHandler: (@Sendable (Diagnostic) -> Void)? = nil) {
        let runState = AudioCaptureRunState()
        let eventSource = PlatformAudioSystemEventSource()
        self.runState = runState
        self.diagnosticHandler = diagnosticHandler
        self.runDiagnosticHandler = nil
        self.audioSessionLifecycle = AudioSessionActivationLifecycle(
            activation: PlatformAudioSessionActivation()
        )
        self.graphPreparation = PlatformAudioCaptureGraphPreparation()
        self.audioSystemEventBridge = AudioCaptureAudioSystemEventBridge(
            source: eventSource,
            runState: runState,
            diagnosticHandler: diagnosticHandler,
            runDiagnosticHandler: nil
        )
    }

    init(runDiagnosticHandler: @escaping @Sendable (UInt64, Diagnostic) -> Void) {
        let runState = AudioCaptureRunState()
        let eventSource = PlatformAudioSystemEventSource()
        self.runState = runState
        self.diagnosticHandler = nil
        self.runDiagnosticHandler = runDiagnosticHandler
        self.audioSessionLifecycle = AudioSessionActivationLifecycle(
            activation: PlatformAudioSessionActivation()
        )
        self.graphPreparation = PlatformAudioCaptureGraphPreparation()
        self.audioSystemEventBridge = AudioCaptureAudioSystemEventBridge(
            source: eventSource,
            runState: runState,
            diagnosticHandler: nil,
            runDiagnosticHandler: runDiagnosticHandler
        )
    }

    init(
        audioSystemEventSource: any AudioSystemEventSource,
        runDiagnosticHandler: @escaping @Sendable (UInt64, Diagnostic) -> Void
    ) {
        let runState = AudioCaptureRunState()
        self.runState = runState
        self.diagnosticHandler = nil
        self.runDiagnosticHandler = runDiagnosticHandler
        self.audioSessionLifecycle = AudioSessionActivationLifecycle(
            activation: PlatformAudioSessionActivation()
        )
        self.graphPreparation = PlatformAudioCaptureGraphPreparation()
        self.audioSystemEventBridge = AudioCaptureAudioSystemEventBridge(
            source: audioSystemEventSource,
            runState: runState,
            diagnosticHandler: nil,
            runDiagnosticHandler: runDiagnosticHandler
        )
    }

    init(
        audioSessionActivation: any AudioSessionActivating,
        audioSystemEventSource: any AudioSystemEventSource = PlatformAudioSystemEventSource(),
        graphPreparation: any AudioCaptureGraphPreparing = PlatformAudioCaptureGraphPreparation(),
        diagnosticHandler: (@Sendable (Diagnostic) -> Void)? = nil
    ) {
        let runState = AudioCaptureRunState()
        self.runState = runState
        self.diagnosticHandler = diagnosticHandler
        self.runDiagnosticHandler = nil
        self.audioSessionLifecycle = AudioSessionActivationLifecycle(
            activation: audioSessionActivation
        )
        self.graphPreparation = graphPreparation
        self.audioSystemEventBridge = AudioCaptureAudioSystemEventBridge(
            source: audioSystemEventSource,
            runState: runState,
            diagnosticHandler: diagnosticHandler,
            runDiagnosticHandler: nil
        )
    }

    /// 开始录音。chunkHandler 在音频线程回调；levelHandler 返回 0~1 峰值电平。
    public func start(chunkByteCount: Int = AudioCapture.chunkBytes,
                      chunkHandler: @escaping (Data) -> Void,
                      levelHandler: ((Float) -> Void)? = nil) throws {
        let callbacks = LegacyAudioCaptureCallbacks(
            chunkHandler: chunkHandler,
            levelHandler: levelHandler
        )
        let runLevelHandler: (@Sendable (UInt64, Float) -> Void)?
        if callbacks.levelHandler != nil {
            runLevelHandler = { _, level in callbacks.levelHandler?(level) }
        } else {
            runLevelHandler = nil
        }
        try startRun(
            callbackToken: nil,
            chunkByteCount: chunkByteCount,
            chunkHandler: { _, data in callbacks.chunkHandler(data) },
            levelHandler: runLevelHandler
        )
    }

    func startRun(
        callbackToken: UInt64?,
        chunkByteCount: Int,
        chunkHandler: @escaping @Sendable (UInt64, Data) -> Void,
        levelHandler: (@Sendable (UInt64, Float) -> Void)? = nil
    ) throws {
        lifecycleOperations.lock()
        defer { lifecycleOperations.unlock() }
        try startRunLocked(
            callbackToken: callbackToken,
            chunkByteCount: chunkByteCount,
            chunkHandler: chunkHandler,
            levelHandler: levelHandler
        )
    }

    private func startRunLocked(
        callbackToken: UInt64?,
        chunkByteCount: Int,
        chunkHandler: @escaping @Sendable (UInt64, Data) -> Void,
        levelHandler: (@Sendable (UInt64, Float) -> Void)?
    ) throws {
        guard !isRunning else { return }
        guard chunkByteCount > 0, chunkByteCount.isMultiple(of: 2) else {
            throw CaptureError.converterFailed
        }

        guard let captureRunID = runState.begin(
            callbackToken: callbackToken,
            chunkByteCount: chunkByteCount,
            chunkHandler: chunkHandler,
            levelHandler: levelHandler
        ) else { return }

        var tappedInput: AVAudioInputNode?
        do {
            try AudioCaptureStartupSequence(
                audioSessionLifecycle: audioSessionLifecycle
            ).start(
                subscribeToAudioSystemEvents: {
                    audioSystemEventBridge.start(captureRunID: captureRunID)
                },
                unsubscribeFromAudioSystemEvents: {
                    audioSystemEventBridge.stop()
                },
                graphOperation: {
                    let graph = try graphPreparation.prepare(engine: engine)
                    let input = graph.input
                    input.installTap(
                        onBus: 0,
                        bufferSize: 4096,
                        format: graph.inputFormat
                    ) { [weak self] buffer, _ in
                        self?.process(
                            buffer: buffer,
                            converter: graph.converter,
                            target: graph.targetFormat,
                            captureRunID: captureRunID
                        )
                    }
                    tappedInput = input
                    engine.prepare()
                    do {
                        try engine.start()
                    } catch {
                        throw CaptureError.engineFailed
                    }
                }
            )
        } catch {
            _ = runState.stop(captureRunID: captureRunID, flushRemainder: false)
            tappedInput?.removeTap(onBus: 0)
            engine.stop()
            throw (error as? CaptureError) ?? CaptureError.engineFailed
        }
    }

    /// 停止录音。flushRemainder 为 true 时把不足 200ms 的尾部数据也发出去。
    public func stop(flushRemainder: Bool = true) {
        lifecycleOperations.lock()
        guard let stoppedRun = runState.stop(flushRemainder: flushRemainder) else {
            lifecycleOperations.unlock()
            return
        }
        audioSystemEventBridge.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioSessionLifecycle.deactivate()
        lifecycleOperations.unlock()
        if let remainder = stoppedRun.remainder {
            stoppedRun.chunkHandler(stoppedRun.callbackToken, remainder)
        }
    }

    private func process(buffer: AVAudioPCMBuffer,
                         converter: AVAudioConverter,
                         target: AVAudioFormat,
                         captureRunID: UInt64) {
        guard runState.isActive(captureRunID: captureRunID) else { return }

        if let channels = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            if frames > 0 {
                for i in 0..<frames {
                    peak = max(peak, abs(channels[0][i]))
                }
                runState.emitLevel(min(peak, 1), captureRunID: captureRunID)
            }
        }

        guard let out = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AVAudioFrameCount(
                Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 128
        ) else { return }

        guard let inputSnapshot = PCMBufferSnapshot(buffer) else {
            reportConversionFailure(.inputSnapshotUnavailable, captureRunID: captureRunID)
            return
        }
        let runState = runState
        let diagnosticHandler = diagnosticHandler
        let runDiagnosticHandler = runDiagnosticHandler
        let reportReconstructionFailure: @Sendable () -> Void = {
            guard let callbackToken = runState.callbackToken(
                captureRunID: captureRunID
            ) else { return }
            let diagnostic = Diagnostic.conversionFailed(.inputReconstructionFailed)
            diagnosticHandler?(diagnostic)
            runDiagnosticHandler?(callbackToken, diagnostic)
        }
        let inputWasConsumed = OSAllocatedUnfairLock(initialState: false)
        var convertError: NSError?
        let status = converter.convert(to: out, error: &convertError) { _, outStatus in
            let shouldProvideInput = inputWasConsumed.withLock { consumed in
                guard !consumed else { return false }
                consumed = true
                return true
            }
            guard shouldProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            guard let nextBuffer = inputSnapshot.makeBuffer() else {
                reportReconstructionFailure()
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return nextBuffer
        }
        guard status != .error else {
            reportConversionFailure(.converterError, captureRunID: captureRunID)
            return
        }
        guard let int16Data = out.int16ChannelData else {
            reportConversionFailure(.outputUnavailable, captureRunID: captureRunID)
            return
        }

        let count = Int(out.frameLength) * 2
        guard count > 0 else { return }
        int16Data[0].withMemoryRebound(to: UInt8.self, capacity: count) { bytes in
            runState.append(
                Data(bytes: bytes, count: count),
                captureRunID: captureRunID
            )
        }
    }

    func reportConversionFailure(_ failure: ConversionFailure) {
        diagnosticHandler?(.conversionFailed(failure))
    }

    private func reportConversionFailure(
        _ failure: ConversionFailure,
        captureRunID: UInt64
    ) {
        guard let callbackToken = runState.callbackToken(captureRunID: captureRunID) else { return }
        let diagnostic = Diagnostic.conversionFailed(failure)
        diagnosticHandler?(diagnostic)
        runDiagnosticHandler?(callbackToken, diagnostic)
    }

    func reportAudioSystemEvent(_ event: AudioSystemEvent) {
        diagnosticHandler?(.audioSystemEvent(event))
    }
}

/// Immutable callback holder crossing AVAudioEngine's callback boundary. The closures are never
/// mutated after initialization; run admission and stale-callback rejection live in the locked
/// `AudioCaptureRunState` rather than in this holder. This preserves the legacy public contract
/// that callbacks run on the audio thread, so callers remain responsible for synchronizing captures.
private final class LegacyAudioCaptureCallbacks: @unchecked Sendable {
    let chunkHandler: (Data) -> Void
    let levelHandler: ((Float) -> Void)?

    init(
        chunkHandler: @escaping (Data) -> Void,
        levelHandler: ((Float) -> Void)?
    ) {
        self.chunkHandler = chunkHandler
        self.levelHandler = levelHandler
    }
}
