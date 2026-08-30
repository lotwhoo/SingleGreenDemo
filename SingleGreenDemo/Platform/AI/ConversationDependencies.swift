import Foundation
import SingleGreenGlassesKit
import UIKit

extension VoiceConversationDependencies {
    @MainActor
    static func live(
        settings: AISettings,
        credentialProvider: (any ConversationCredentialProvider)? = nil,
        telemetry: (any ConversationTelemetrySink)? = nil
    ) -> Self {
        let telemetry = telemetry ?? ConversationTelemetryStore()
        let credentialProvider = credentialProvider
            ?? AIServiceComposition.makeCredentialProvider(settings: settings)
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: credentialProvider,
            makeVoiceActivatedSession: ProductionVoiceActivatedSessionFactory.make
        )
        return VoiceConversationComposition(
            resolver: resolver,
            requestMicrophonePermission: LiveSpeechInputComposition.requestMicrophonePermission,
            sleep: { duration in try await Task.sleep(for: duration) },
            reduceMotion: { UIAccessibility.isReduceMotionEnabled },
            telemetry: telemetry,
            presentationCopy: .singleGreenDemo,
            monotonicNow: { DispatchTime.now().uptimeNanoseconds }
        ).dependencies
    }
}

enum AIServiceComposition {
    @MainActor
    static func makeCredentialProvider(
        settings: AISettings
    ) -> any ConversationCredentialProvider {
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
        return credentialProvider
    }

    @MainActor
    static func makeSpeechCredentialProvider(
        settings: AISettings
    ) -> any SpeechCredentialProvider {
        #if DEBUG
        if settings.buildPolicy.allowsDemoCredentialStorage {
            return DemoSpeechCredentialProvider(settings: settings)
        }
        #endif
        return FailClosedSpeechCredentialProvider()
    }
}
