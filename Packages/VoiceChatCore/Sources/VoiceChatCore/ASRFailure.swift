import Foundation
import ASRDomain

public extension ASRFailure {
    /// Classifies transport failures structurally from their error domain and code.
    /// Localized descriptions and user-info payloads are intentionally ignored.
    static func transport(_ error: Error) -> ASRFailure {
        if let failure = error as? ASRFailure { return failure }
        if let captureError = error as? AudioCapture.CaptureError {
            return audioCapture(captureError)
        }
        if error is ASRError || error is ASRSession.SessionError {
            return categorized(.protocolFailure)
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return categorized(.unknown) }
        switch URLError.Code(rawValue: nsError.code) {
        case .userAuthenticationRequired, .noPermissionsToReadFile:
            return categorized(.unauthorized)
        case .timedOut:
            return categorized(.timeout)
        case .networkConnectionLost, .cancelled:
            return categorized(.connectionLost)
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .callIsActive,
             .dataNotAllowed:
            return categorized(.networkUnavailable)
        default:
            return categorized(.networkUnavailable)
        }
    }

    /// Maps an HTTP or provider protocol status without inspecting provider text.
    static func providerStatus(_ statusCode: UInt32) -> ASRFailure {
        [401, 403].contains(statusCode)
            ? categorized(.unauthorized)
            : categorized(.protocolFailure)
    }

    static func audioCapture(_ error: AudioCapture.CaptureError) -> ASRFailure {
        switch error {
        case .noInput, .converterFailed, .engineFailed:
            categorized(.audioUnavailable)
        }
    }

    static func audioSystemEvent(_ event: AudioCapture.AudioSystemEvent) -> ASRFailure? {
        switch event {
        case .interruptionBegan:
            categorized(.audioInterrupted)
        case .routeChanged, .mediaServicesReset:
            categorized(.audioUnavailable)
        case .interruptionEnded:
            nil
        }
    }

    /// Creates a failure from a reviewed internal category without accepting dynamic error text.
}
