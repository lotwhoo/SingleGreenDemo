import AVFoundation
import os

protocol AudioSystemEventSource: Sendable {
    func start(handler: @escaping @Sendable (AudioCapture.AudioSystemEvent) -> Void)
    func stop()
}

/// Owns the platform notification subscription for one capture run. Its fields are immutable and
/// all mutable run state is synchronized by `AudioCaptureRunState`; notification delivery can race
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

/// NotificationCenter callbacks can arrive concurrently. Observer generation and token replacement
/// are guarded by `observerState`; NotificationCenter owns callback registration/removal safety.
final class PlatformAudioSystemEventSource: AudioSystemEventSource, @unchecked Sendable {
    #if os(iOS)
    /// NotificationCenter owns these opaque tokens. They are only replaced while `observerState`
    /// is locked and are only passed back to NotificationCenter for removal.
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
