import Foundation

/// Provider-neutral, privacy-safe ASR failure passed across VoiceChatCore boundaries.
/// `userSafeMessage` is reviewed static copy and must never contain provider payloads,
/// framework-localized descriptions, credentials, transcripts, or device identifiers.
public struct ASRFailure: Error, Equatable, Sendable {
    public enum Code: String, Equatable, Sendable {
        case unauthorized
        case networkUnavailable
        case timeout
        case connectionLost
        case protocolFailure
        case audioInterrupted
        case audioUnavailable
        case voiceActivityUnavailable
        case voiceActivityProcessingFailed
        case audioCaptureOverrun
        case uploadBackpressureExceeded
        case unknown
    }

    public let code: Code
    public let userSafeMessage: String?

    public init(code: Code) {
        self.code = code
        self.userSafeMessage = nil
    }

    private init(code: Code, reviewedUserSafeMessage: String) {
        self.code = code
        self.userSafeMessage = reviewedUserSafeMessage
    }

    /// Classifies transport failures structurally from their error domain and code.
    /// Localized descriptions and user-info payloads are intentionally ignored.
    public static func transport(_ error: Error) -> ASRFailure {
        if let failure = error as? ASRFailure { return failure }
        if let captureError = error as? AudioCapture.CaptureError {
            return audioCapture(captureError)
        }
        if error is ASRError || error is ASRSession.SessionError {
            return make(.protocolFailure)
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return make(.unknown) }
        switch URLError.Code(rawValue: nsError.code) {
        case .userAuthenticationRequired, .noPermissionsToReadFile:
            return make(.unauthorized)
        case .timedOut:
            return make(.timeout)
        case .networkConnectionLost, .cancelled:
            return make(.connectionLost)
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .callIsActive,
             .dataNotAllowed:
            return make(.networkUnavailable)
        default:
            return make(.networkUnavailable)
        }
    }

    /// Maps an HTTP or provider protocol status without inspecting provider text.
    public static func providerStatus(_ statusCode: UInt32) -> ASRFailure {
        [401, 403].contains(statusCode) ? make(.unauthorized) : make(.protocolFailure)
    }

    public static func audioCapture(_ error: AudioCapture.CaptureError) -> ASRFailure {
        switch error {
        case .noInput, .converterFailed, .engineFailed:
            make(.audioUnavailable)
        }
    }

    public static func audioSystemEvent(_ event: AudioCapture.AudioSystemEvent) -> ASRFailure? {
        switch event {
        case .interruptionBegan:
            make(.audioInterrupted)
        case .routeChanged, .mediaServicesReset:
            make(.audioUnavailable)
        case .interruptionEnded:
            nil
        }
    }

    /// Creates a failure from a reviewed internal category without accepting dynamic error text.
    static func categorized(_ code: Code) -> ASRFailure {
        make(code)
    }

    private static func make(_ code: Code) -> ASRFailure {
        ASRFailure(code: code, reviewedUserSafeMessage: safeMessage(for: code))
    }

    private static func safeMessage(for code: Code) -> String {
        switch code {
        case .unauthorized:
            "语音服务凭证未通过验证。"
        case .networkUnavailable:
            "网络或语音服务暂时不可用。"
        case .timeout:
            "语音服务连接超时，请重试。"
        case .connectionLost:
            "语音服务连接已中断，请重试。"
        case .protocolFailure:
            "语音服务响应异常，请稍后重试。"
        case .audioInterrupted:
            "录音已被系统中断，请重试。"
        case .audioUnavailable:
            "当前无法使用麦克风，请检查音频设备。"
        case .voiceActivityUnavailable:
            "本地语音活动检测暂时不可用。"
        case .voiceActivityProcessingFailed:
            "本地语音活动检测失败，请重试。"
        case .audioCaptureOverrun:
            "本地音频处理暂时跟不上录音速度，请重试。"
        case .uploadBackpressureExceeded:
            "语音服务处理速度暂时过慢，请重试。"
        case .unknown:
            "语音识别暂时不可用，请稍后重试。"
        }
    }
}
