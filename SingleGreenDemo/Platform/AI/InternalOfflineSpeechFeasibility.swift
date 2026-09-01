#if INTERNAL_DIAGNOSTICS
import AVFAudio
import Foundation
import Speech

enum OfflineSpeechAssetStatus: String, Equatable, Sendable {
    case unavailable
    case unsupported
    case supported
    case downloading
    case installed
}

enum OfflineSpeechPreparationStatus: String, Equatable, Sendable {
    case notAttempted = "not_attempted"
    case succeeded
    case failed
}

struct OfflineSpeechCapabilitySnapshot: Equatable, Sendable {
    let requestedLocaleIdentifier: String
    let resolvedLocaleIdentifier: String?
    let transcriberAvailable: Bool
    let assetStatus: OfflineSpeechAssetStatus
    let sampleRate: Double?
    let channelCount: Int?
    let preparationStatus: OfflineSpeechPreparationStatus
    let preparationMilliseconds: Int?

    var diagnosticLine: String {
        [
            "requested_locale=\(requestedLocaleIdentifier)",
            "resolved_locale=\(resolvedLocaleIdentifier ?? "none")",
            "available=\(transcriberAvailable)",
            "asset=\(assetStatus.rawValue)",
            "sample_rate_hz=\(sampleRate.map { String(Int($0.rounded())) } ?? "none")",
            "channels=\(channelCount.map(String.init) ?? "none")",
            "preparation=\(preparationStatus.rawValue)",
            "preparation_ms=\(preparationMilliseconds.map(String.init) ?? "none")"
        ].joined(separator: " ")
    }
}

protocol OfflineSpeechCapabilityChecking: Sendable {
    func check(localeIdentifier: String) async -> OfflineSpeechCapabilitySnapshot
}

struct AppleOfflineSpeechCapabilityChecker: OfflineSpeechCapabilityChecking {
    func check(localeIdentifier: String = "zh-CN") async -> OfflineSpeechCapabilitySnapshot {
        guard SpeechTranscriber.isAvailable else {
            return unavailableSnapshot(localeIdentifier: localeIdentifier)
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(
            equivalentTo: requestedLocale
        ) else {
            return OfflineSpeechCapabilitySnapshot(
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: nil,
                transcriberAvailable: true,
                assetStatus: .unsupported,
                sampleRate: nil,
                channelCount: nil,
                preparationStatus: .notAttempted,
                preparationMilliseconds: nil
            )
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]
        let inventoryStatus = await AssetInventory.status(forModules: modules)
        let status = Self.map(inventoryStatus)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)

        guard status == .installed else {
            return OfflineSpeechCapabilitySnapshot(
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: supportedLocale.identifier,
                transcriberAvailable: true,
                assetStatus: status,
                sampleRate: format?.sampleRate,
                channelCount: format.map { Int($0.channelCount) },
                preparationStatus: .notAttempted,
                preparationMilliseconds: nil
            )
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        do {
            try await analyzer.prepareToAnalyze(in: format)
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            await analyzer.cancelAndFinishNow()
            await SpeechModels.endRetention()
            return OfflineSpeechCapabilitySnapshot(
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: supportedLocale.identifier,
                transcriberAvailable: true,
                assetStatus: status,
                sampleRate: format?.sampleRate,
                channelCount: format.map { Int($0.channelCount) },
                preparationStatus: .succeeded,
                preparationMilliseconds: Self.milliseconds(elapsed)
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            await SpeechModels.endRetention()
            return OfflineSpeechCapabilitySnapshot(
                requestedLocaleIdentifier: localeIdentifier,
                resolvedLocaleIdentifier: supportedLocale.identifier,
                transcriberAvailable: true,
                assetStatus: status,
                sampleRate: format?.sampleRate,
                channelCount: format.map { Int($0.channelCount) },
                preparationStatus: .failed,
                preparationMilliseconds: nil
            )
        }
    }

    static func map(_ status: AssetInventory.Status) -> OfflineSpeechAssetStatus {
        switch status {
        case .unsupported: .unsupported
        case .supported: .supported
        case .downloading: .downloading
        case .installed: .installed
        @unknown default: .unavailable
        }
    }

    private func unavailableSnapshot(
        localeIdentifier: String
    ) -> OfflineSpeechCapabilitySnapshot {
        OfflineSpeechCapabilitySnapshot(
            requestedLocaleIdentifier: localeIdentifier,
            resolvedLocaleIdentifier: nil,
            transcriberAvailable: false,
            assetStatus: .unavailable,
            sampleRate: nil,
            channelCount: nil,
            preparationStatus: .notAttempted,
            preparationMilliseconds: nil
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Int {
        let milliseconds = nanoseconds / 1_000_000
        return milliseconds > UInt64(Int.max) ? Int.max : Int(milliseconds)
    }
}
#endif
