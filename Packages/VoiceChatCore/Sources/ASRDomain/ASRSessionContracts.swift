import Foundation

public enum ASRSessionState: Sendable, Equatable {
    case idle
    case starting
    case recording
    case finalizing
    case finished
    case failed(ASRFailure)
}

public enum ASRSessionEvent: Sendable {
    case state(ASRSessionState)
    case transcript(String)
    case utterance(String)
    case level(Float)
    case error(ASRFailure)
}

public enum ASRSessionError: Error, LocalizedError, Equatable, Sendable {
    case busy
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .busy: "ASR 会话已在进行中"
        case .notRunning: "ASR 会话未启动"
        }
    }
}
