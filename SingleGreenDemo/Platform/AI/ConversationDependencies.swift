import AVFoundation
import Foundation
import SingleGreenGlassesKit
import UIKit

extension VoiceConversationDependencies {
    @MainActor
    static func live(settings: AISettings) -> Self {
        let telemetry = ConversationTelemetryStore()
        #if DEBUG
        let credentialProvider: any ConversationCredentialProvider
        if settings.buildPolicy.allowsDemoCredentialStorage {
            credentialProvider = DemoKeychainCredentialProvider(settings: settings)
        } else {
            credentialProvider = ServerIssuedCredentialProvider(
                transport: FailClosedServerCredentialTransport()
            )
        }
        #else
        let credentialProvider: any ConversationCredentialProvider = ServerIssuedCredentialProvider(
            transport: FailClosedServerCredentialTransport()
        )
        #endif

        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: credentialProvider,
            makeVoiceActivatedSession: ProductionVoiceActivatedSessionFactory.make
        )
        return VoiceConversationComposition(
            resolver: resolver,
            requestMicrophonePermission: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:
                    return true
                case .denied:
                    return false
                case .undetermined:
                    return await withCheckedContinuation { continuation in
                        AVAudioApplication.requestRecordPermission {
                            continuation.resume(returning: $0)
                        }
                    }
                @unknown default:
                    return false
                }
            },
            sleep: { duration in try await Task.sleep(for: duration) },
            reduceMotion: { UIAccessibility.isReduceMotionEnabled },
            telemetry: telemetry,
            presentationCopy: .singleGreenDemo,
            monotonicNow: { DispatchTime.now().uptimeNanoseconds }
        ).dependencies
    }
}
