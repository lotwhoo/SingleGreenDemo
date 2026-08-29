import AVFoundation

protocol AudioSessionActivating {
    func activate() throws
    func deactivate()
}

struct PlatformAudioSessionActivation: AudioSessionActivating {
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

struct PlatformAudioCaptureGraphPreparation: AudioCaptureGraphPreparing {
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
