import AVFoundation
import os
#if os(iOS)
import UIKit
#endif

protocol AudioSessionActivating {
    func activate() throws
    func deactivate()
}

private struct PlatformAudioSessionActivation: AudioSessionActivating {
    func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif
    }

    func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

struct AudioSessionActivationLifecycle {
    private let activation: any AudioSessionActivating

    init(activation: any AudioSessionActivating) {
        self.activation = activation
    }

    func withActivatedSession<Result>(_ operation: () throws -> Result) throws -> Result {
        do {
            try activation.activate()
            return try operation()
        } catch {
            activation.deactivate()
            throw error
        }
    }

    func deactivate() {
        activation.deactivate()
    }
}

struct AudioCaptureStartupSequence {
    let audioSessionLifecycle: AudioSessionActivationLifecycle

    func start<Result>(
        subscribeToAudioSystemEvents: () -> Void,
        unsubscribeFromAudioSystemEvents: () -> Void,
        graphOperation: () throws -> Result
    ) throws -> Result {
        subscribeToAudioSystemEvents()
        do {
            return try audioSessionLifecycle.withActivatedSession(graphOperation)
        } catch {
            unsubscribeFromAudioSystemEvents()
            throw error
        }
    }
}

struct AudioRouteChangeReportingPolicy {
    /// Setting the app's own audio category can enqueue a route-change notification. That
    /// configuration event is not evidence that the active microphone route became unusable.
    static func shouldReport(isCategoryChange: Bool) -> Bool {
        !isCategoryChange
    }
}

struct PreparedAudioCaptureGraph {
    let input: AVAudioInputNode
    let inputFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    let converter: AVAudioConverter
}

protocol AudioCaptureGraphPreparing {
    func prepare(engine: AVAudioEngine) throws -> PreparedAudioCaptureGraph
}

private struct PlatformAudioCaptureGraphPreparation: AudioCaptureGraphPreparing {
    func prepare(engine: AVAudioEngine) throws -> PreparedAudioCaptureGraph {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCapture.CaptureError.noInput
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioCapture.sampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCapture.CaptureError.converterFailed
        }

        return PreparedAudioCaptureGraph(
            input: input,
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            converter: converter
        )
    }
}

/// 麦克风采集：AVAudioEngine 输入 → AVAudioConverter → 16kHz / 16bit / 单声道 PCM
/// Legacy callers receive 200 ms chunks by default. Local VAD callers can request exact 20 ms
/// frames without changing the converter or duplicating capture code.
public final class AudioCapture {

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

    /// Typed seam for AVAudioSession notifications. It carries no route names,
    /// device identifiers, framework payloads, or captured audio.
    public enum AudioSystemEvent: Sendable, Equatable {
        case interruptionBegan
        case interruptionEnded
        case routeChanged
        case mediaServicesReset
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

    public var isRunning: Bool { runState.isRunning }

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
        guard let stoppedRun = runState.stop(flushRemainder: flushRemainder) else { return }
        audioSystemEventBridge.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioSessionLifecycle.deactivate()
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

protocol AudioSystemEventSource: Sendable {
    func start(handler: @escaping @Sendable (AudioCapture.AudioSystemEvent) -> Void)
    func stop()
}

/// Owns the platform notification subscription for one capture run. Notification delivery can race
/// stop/rearm, so every callback is validated against the immutable capture run ID before emission.
final class AudioCaptureAudioSystemEventBridge: @unchecked Sendable {
    private let source: any AudioSystemEventSource
    private let runState: AudioCaptureRunState
    private let diagnosticHandler: (@Sendable (AudioCapture.Diagnostic) -> Void)?
    private let runDiagnosticHandler: (@Sendable (UInt64, AudioCapture.Diagnostic) -> Void)?

    init(
        source: any AudioSystemEventSource,
        runState: AudioCaptureRunState,
        diagnosticHandler: (@Sendable (AudioCapture.Diagnostic) -> Void)?,
        runDiagnosticHandler: (@Sendable (UInt64, AudioCapture.Diagnostic) -> Void)?
    ) {
        self.source = source
        self.runState = runState
        self.diagnosticHandler = diagnosticHandler
        self.runDiagnosticHandler = runDiagnosticHandler
    }

    func start(captureRunID: UInt64) {
        source.start { [weak self] event in
            self?.receive(event, captureRunID: captureRunID)
        }
    }

    func stop() {
        source.stop()
    }

    private func receive(_ event: AudioCapture.AudioSystemEvent, captureRunID: UInt64) {
        guard let callbackToken = runState.callbackToken(captureRunID: captureRunID) else { return }
        let diagnostic = AudioCapture.Diagnostic.audioSystemEvent(event)
        diagnosticHandler?(diagnostic)
        runDiagnosticHandler?(callbackToken, diagnostic)
    }
}

final class PlatformAudioSystemEventSource: AudioSystemEventSource, @unchecked Sendable {
    #if os(iOS)
    private struct ObserverTokens: @unchecked Sendable {
        let values: [NSObjectProtocol]

        static let empty = ObserverTokens(values: [])
    }

    private struct ObserverState: Sendable {
        var generation: UInt64 = 0
        var observers = ObserverTokens.empty
    }

    private let notificationCenter: NotificationCenter
    private let observerState = OSAllocatedUnfairLock(initialState: ObserverState())

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start(handler: @escaping @Sendable (AudioCapture.AudioSystemEvent) -> Void) {
        let (generation, removed) = observerState.withLock { state in
            state.generation &+= 1
            let removed = state.observers
            state.observers = .empty
            return (state.generation, removed)
        }
        removed.values.forEach(notificationCenter.removeObserver)
        let interruption = notificationCenter.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let rawValue = (
                notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber
            )?.uintValue,
            let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
            switch type {
            case .began:
                handler(.interruptionBegan)
            case .ended:
                handler(.interruptionEnded)
            @unknown default:
                return
            }
        }
        let routeChange = notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            let reasonRawValue = (
                notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber
            )?.uintValue
            let isCategoryChange = reasonRawValue
                == AVAudioSession.RouteChangeReason.categoryChange.rawValue
            guard AudioRouteChangeReportingPolicy.shouldReport(
                isCategoryChange: isCategoryChange
            ) else { return }
            handler(.routeChanged)
        }
        let mediaServicesReset = notificationCenter.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { _ in
            handler(.mediaServicesReset)
        }
        let added = ObserverTokens(values: [interruption, routeChange, mediaServicesReset])
        let accepted = observerState.withLock { state in
            guard state.generation == generation else { return false }
            state.observers = added
            return true
        }
        if !accepted { added.values.forEach(notificationCenter.removeObserver) }
    }

    func stop() {
        let removed = observerState.withLock { state in
            state.generation &+= 1
            let removed = state.observers
            state.observers = .empty
            return removed
        }
        removed.values.forEach(notificationCenter.removeObserver)
    }

    deinit {
        stop()
    }
    #else
    init() {}
    func start(handler: @escaping @Sendable (AudioCapture.AudioSystemEvent) -> Void) {}
    func stop() {}
    #endif
}

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

final class AudioCaptureRunState: @unchecked Sendable {
    struct StoppedRun: Sendable {
        let callbackToken: UInt64
        let chunkHandler: @Sendable (UInt64, Data) -> Void
        let remainder: Data?
    }

    private struct ActiveRun: Sendable {
        let captureRunID: UInt64
        let callbackToken: UInt64
        let chunkByteCount: Int
        let chunkHandler: @Sendable (UInt64, Data) -> Void
        let levelHandler: (@Sendable (UInt64, Float) -> Void)?
        var pending = Data()
    }

    private struct State: Sendable {
        var nextCaptureRunID: UInt64 = 0
        var activeRun: ActiveRun?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isRunning: Bool {
        state.withLock { $0.activeRun != nil }
    }

    func begin(
        callbackToken: UInt64?,
        chunkByteCount: Int,
        chunkHandler: @escaping @Sendable (UInt64, Data) -> Void,
        levelHandler: (@Sendable (UInt64, Float) -> Void)?
    ) -> UInt64? {
        state.withLock { state in
            guard state.activeRun == nil else { return nil }
            state.nextCaptureRunID &+= 1
            let captureRunID = state.nextCaptureRunID
            state.activeRun = ActiveRun(
                captureRunID: captureRunID,
                callbackToken: callbackToken ?? captureRunID,
                chunkByteCount: chunkByteCount,
                chunkHandler: chunkHandler,
                levelHandler: levelHandler
            )
            return captureRunID
        }
    }

    func isActive(captureRunID: UInt64) -> Bool {
        state.withLock { $0.activeRun?.captureRunID == captureRunID }
    }

    func callbackToken(captureRunID: UInt64) -> UInt64? {
        state.withLock { state in
            guard state.activeRun?.captureRunID == captureRunID else { return nil }
            return state.activeRun?.callbackToken
        }
    }

    func append(_ data: Data, captureRunID: UInt64) {
        let emission: (UInt64, @Sendable (UInt64, Data) -> Void, [Data])? = state.withLock { state in
            guard var activeRun = state.activeRun,
                  activeRun.captureRunID == captureRunID else { return nil }
            activeRun.pending.append(data)
            var chunks: [Data] = []
            while activeRun.pending.count >= activeRun.chunkByteCount {
                chunks.append(Data(activeRun.pending.prefix(activeRun.chunkByteCount)))
                activeRun.pending.removeFirst(activeRun.chunkByteCount)
            }
            state.activeRun = activeRun
            return (activeRun.callbackToken, activeRun.chunkHandler, chunks)
        }
        guard let emission else { return }
        for chunk in emission.2 {
            emission.1(emission.0, chunk)
        }
    }

    func emitLevel(_ level: Float, captureRunID: UInt64) {
        let emission: (UInt64, @Sendable (UInt64, Float) -> Void)? = state.withLock { state in
            guard let activeRun = state.activeRun,
                  activeRun.captureRunID == captureRunID,
                  let levelHandler = activeRun.levelHandler else { return nil }
            return (activeRun.callbackToken, levelHandler)
        }
        if let (callbackToken, levelHandler) = emission {
            levelHandler(callbackToken, level)
        }
    }

    func stop(
        captureRunID: UInt64? = nil,
        flushRemainder: Bool
    ) -> StoppedRun? {
        state.withLock { state in
            guard let activeRun = state.activeRun,
                  captureRunID == nil || activeRun.captureRunID == captureRunID else { return nil }
            state.activeRun = nil
            return StoppedRun(
                callbackToken: activeRun.callbackToken,
                chunkHandler: activeRun.chunkHandler,
                remainder: flushRemainder && !activeRun.pending.isEmpty ? activeRun.pending : nil
            )
        }
    }
}

/// Sendable copy used to reconstruct an AVAudioPCMBuffer inside AVAudioConverter's Sendable input
/// callback. This keeps the framework object itself from crossing the callback isolation boundary.
struct PCMBufferSnapshot: Sendable {
    private struct StreamDescription: Sendable {
        let sampleRate: Double
        let formatID: UInt32
        let formatFlags: UInt32
        let bytesPerPacket: UInt32
        let framesPerPacket: UInt32
        let bytesPerFrame: UInt32
        let channelsPerFrame: UInt32
        let bitsPerChannel: UInt32
        let reserved: UInt32

        init(_ value: AudioStreamBasicDescription) {
            sampleRate = value.mSampleRate
            formatID = value.mFormatID
            formatFlags = value.mFormatFlags
            bytesPerPacket = value.mBytesPerPacket
            framesPerPacket = value.mFramesPerPacket
            bytesPerFrame = value.mBytesPerFrame
            channelsPerFrame = value.mChannelsPerFrame
            bitsPerChannel = value.mBitsPerChannel
            reserved = value.mReserved
        }

        func makeValue() -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytesPerPacket,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channelsPerFrame,
                mBitsPerChannel: bitsPerChannel,
                mReserved: reserved
            )
        }
    }

    private struct ChannelDescription: Sendable {
        let label: UInt32
        let flags: UInt32
        let coordinate0: Float32
        let coordinate1: Float32
        let coordinate2: Float32

        init(_ value: AudioChannelDescription) {
            label = value.mChannelLabel
            flags = value.mChannelFlags.rawValue
            coordinate0 = value.mCoordinates.0
            coordinate1 = value.mCoordinates.1
            coordinate2 = value.mCoordinates.2
        }

        func makeValue() -> AudioChannelDescription {
            AudioChannelDescription(
                mChannelLabel: label,
                mChannelFlags: AudioChannelFlags(rawValue: flags),
                mCoordinates: (coordinate0, coordinate1, coordinate2)
            )
        }
    }

    private struct ChannelLayout: Sendable {
        let tag: UInt32
        let bitmap: UInt32
        let descriptions: [ChannelDescription]

        init(_ value: AVAudioChannelLayout) {
            let layout = value.layout.pointee
            tag = layout.mChannelLayoutTag
            bitmap = layout.mChannelBitmap.rawValue
            let descriptionCount = Int(layout.mNumberChannelDescriptions)
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.offset(
                of: \.mChannelDescriptions
            )!
            let descriptionPointer = UnsafeRawPointer(value.layout)
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            descriptions = (0..<descriptionCount).map { ChannelDescription(descriptionPointer[$0]) }
        }

        func makeValue() -> AVAudioChannelLayout? {
            let descriptionOffset = MemoryLayout<AudioChannelLayout>.offset(
                of: \.mChannelDescriptions
            )!
            let byteCount = descriptionOffset
                + max(descriptions.count, 1) * MemoryLayout<AudioChannelDescription>.stride
            let rawLayout = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: MemoryLayout<AudioChannelLayout>.alignment
            )
            defer { rawLayout.deallocate() }
            rawLayout.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

            let layoutPointer = rawLayout.assumingMemoryBound(to: AudioChannelLayout.self)
            layoutPointer.pointee.mChannelLayoutTag = tag
            layoutPointer.pointee.mChannelBitmap = AudioChannelBitmap(rawValue: bitmap)
            layoutPointer.pointee.mNumberChannelDescriptions = UInt32(descriptions.count)
            let descriptionPointer = rawLayout
                .advanced(by: descriptionOffset)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            for (index, description) in descriptions.enumerated() {
                descriptionPointer[index] = description.makeValue()
            }
            return AVAudioChannelLayout(layout: layoutPointer)
        }
    }

    private struct BufferBytes: Sendable {
        let channelCount: UInt32
        let data: Data
    }

    private let streamDescription: StreamDescription
    private let channelLayout: ChannelLayout?
    let frameLength: AVAudioFrameCount
    private let audioBuffers: [BufferBytes]

    init?(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength <= buffer.frameCapacity else { return nil }
        streamDescription = StreamDescription(buffer.format.streamDescription.pointee)
        channelLayout = buffer.format.channelLayout.map(ChannelLayout.init)
        frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var copiedBuffers: [BufferBytes] = []
        copiedBuffers.reserveCapacity(sourceBuffers.count)
        for source in sourceBuffers {
            let byteCount = Int(source.mDataByteSize)
            guard byteCount == 0 || source.mData != nil else { return nil }
            let bytes = source.mData.map { Data(bytes: $0, count: byteCount) } ?? Data()
            copiedBuffers.append(BufferBytes(channelCount: source.mNumberChannels, data: bytes))
        }
        audioBuffers = copiedBuffers
    }

    func makeBuffer() -> AVAudioPCMBuffer? {
        var sourceDescription = streamDescription.makeValue()
        guard let format = AVAudioFormat(
                streamDescription: &sourceDescription,
                channelLayout: channelLayout?.makeValue()
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        buffer.frameLength = frameLength
        let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard destinations.count == audioBuffers.count else { return nil }

        for index in destinations.indices {
            let source = audioBuffers[index]
            let destination = destinations[index]
            guard destination.mNumberChannels == source.channelCount,
                  Int(destination.mDataByteSize) >= source.data.count,
                  source.data.isEmpty || destination.mData != nil else { return nil }
            if let destinationData = destination.mData {
                source.data.copyBytes(
                    to: destinationData.assumingMemoryBound(to: UInt8.self),
                    count: source.data.count
                )
            }
            destinations[index].mDataByteSize = UInt32(source.data.count)
        }
        return buffer
    }
}
