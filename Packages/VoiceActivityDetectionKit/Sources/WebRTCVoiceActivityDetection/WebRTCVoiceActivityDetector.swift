import CWebRTCVAD
import VoiceActivityDetectionKit

/// WebRTC VAD operating modes. Higher modes reject more non-speech input but
/// can also miss more speech; the integer values are the upstream ABI contract.
public enum WebRTCVADAggressiveness: Int, CaseIterable, Sendable {
    case quality = 0
    case lowBitrate = 1
    case aggressive = 2
    case veryAggressive = 3

    public init(validatingMode mode: Int) throws {
        guard let value = Self(rawValue: mode) else {
            throw WebRTCVoiceActivityDetectorError.invalidAggressivenessMode(mode)
        }
        self = value
    }
}

/// Stable errors surfaced by the production adapter without exposing PCM or
/// upstream diagnostic strings.
public enum WebRTCVoiceActivityDetectorError: Error, Equatable, Sendable {
    case allocationFailed
    case initializationFailed
    case invalidAggressivenessMode(Int)
    case modeConfigurationFailed(Int)
    case processingFailed(sampleRateHertz: Int, sampleCount: Int)
}

/// Actor-confined production detector backed by one WebRTC `VadInst`.
///
/// The `speechProbability` in returned observations is exactly `0` or `1` for
/// compatibility with the provider-neutral port. It is not a calibrated
/// probability or quality score.
public actor WebRTCVoiceActivityDetector: VoiceActivityDetecting {
    private let aggressiveness: WebRTCVADAggressiveness
    private let api: WebRTCVADAPI
    private let handle: WebRTCVADHandle
    private var deferredResetFailure: WebRTCVoiceActivityDetectorError?

    public init(aggressiveness: WebRTCVADAggressiveness = .aggressive) throws {
        try self.init(aggressiveness: aggressiveness, api: .live)
    }

    init(
        aggressiveness: WebRTCVADAggressiveness = .aggressive,
        api: WebRTCVADAPI
    ) throws {
        self.aggressiveness = aggressiveness
        self.api = api

        guard let handle = api.create() else {
            throw WebRTCVoiceActivityDetectorError.allocationFailed
        }
        guard api.initialize(handle) == 0 else {
            api.free(handle)
            throw WebRTCVoiceActivityDetectorError.initializationFailed
        }
        guard api.setMode(handle, aggressiveness.rawValue) == 0 else {
            api.free(handle)
            throw WebRTCVoiceActivityDetectorError.modeConfigurationFailed(
                aggressiveness.rawValue
            )
        }
        self.handle = handle
    }

    deinit {
        api.free(handle)
    }

    public func observation(for frame: VADPCMFrame) async throws -> VoiceActivityObservation {
        try Task.checkCancellation()

        if let deferredResetFailure {
            throw deferredResetFailure
        }

        // VADPCMFrame.samples decodes little-endian PCM without unaligned binding.
        let samples = frame.samples
        let result = samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Int32(-1)
            }
            return api.process(
                handle,
                VADPCMFrame.sampleRateHertz,
                baseAddress,
                buffer.count
            )
        }
        guard result == 0 || result == 1 else {
            throw WebRTCVoiceActivityDetectorError.processingFailed(
                sampleRateHertz: VADPCMFrame.sampleRateHertz,
                sampleCount: samples.count
            )
        }

        try Task.checkCancellation()
        let isSpeech = result == 1
        return try VoiceActivityObservation(
            speechProbability: isSpeech ? 1 : 0,
            isSpeech: isSpeech
        )
    }

    public func reset() async {
        deferredResetFailure = nil
        guard api.initialize(handle) == 0 else {
            deferredResetFailure = .initializationFailed
            return
        }
        guard api.setMode(handle, aggressiveness.rawValue) == 0 else {
            deferredResetFailure = .modeConfigurationFailed(aggressiveness.rawValue)
            return
        }
    }
}

struct WebRTCVADAPI: @unchecked Sendable {
    let create: @Sendable () -> WebRTCVADHandle?
    let initialize: @Sendable (WebRTCVADHandle) -> Int32
    let setMode: @Sendable (WebRTCVADHandle, Int) -> Int32
    let process: @Sendable (WebRTCVADHandle, Int, UnsafePointer<Int16>, Int) -> Int32
    let free: @Sendable (WebRTCVADHandle) -> Void

    static func handleIfAllocated(_ rawValue: OpaquePointer?) -> WebRTCVADHandle? {
        rawValue.map(WebRTCVADHandle.init)
    }

    static let live = Self(
        create: { handleIfAllocated(SGDWebRtcVad_Create()) },
        initialize: { SGDWebRtcVad_Init($0.rawValue) },
        setMode: { SGDWebRtcVad_SetMode($0.rawValue, Int32($1)) },
        process: { handle, rate, samples, count in
            SGDWebRtcVad_Process(
                handle.rawValue,
                Int32(rate),
                samples,
                count
            )
        },
        free: { SGDWebRtcVad_Free($0.rawValue) }
    )
}

struct WebRTCVADHandle: @unchecked Sendable {
    let rawValue: OpaquePointer
}
