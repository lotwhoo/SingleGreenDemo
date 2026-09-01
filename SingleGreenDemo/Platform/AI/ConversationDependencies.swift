import Foundation
import SingleGreenGlassesKit
import UIKit

extension VoiceConversationDependencies {
    @MainActor
    static func live(
        settings: AISettings,
        credentialProvider: (any ConversationCredentialProvider)? = nil,
        microphoneLeaseCoordinator: MicrophoneLeaseCoordinator? = nil,
        telemetry: (any ConversationTelemetrySink)? = nil
    ) -> Self {
        let telemetry = telemetry ?? NoopConversationTelemetry()
        let monotonicNow: @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
        let credentialProvider = credentialProvider
            ?? AIServiceComposition.makeCredentialProvider(settings: settings)
        #if INTERNAL_DIAGNOSTICS
        let diagnosticSink = telemetry as? any InternalDiagnosticsLineSink
        let vadDiagnosticsWiring = InternalVADDiagnosticsLiveComposition.make(
            diagnosticSink: diagnosticSink,
            monotonicNow: monotonicNow
        )
        precondition(
            vadDiagnosticsWiring.marker == InternalVADDiagnosticsLiveComposition.wiringMarker
        )
        let makeVoiceActivatedSession = vadDiagnosticsWiring.makeVoiceActivatedSession
        #else
        let makeVoiceActivatedSession: ConversationPreparationResolver.VoiceActivatedFactory = {
            try ProductionVoiceActivatedSessionFactory.make(configuration: $0, diagnostics: nil)
        }
        #endif
        let resolver = ConversationPreparationResolver(
            settings: settings,
            credentialProvider: credentialProvider,
            makeVoiceActivatedSession: makeVoiceActivatedSession,
            microphoneLeaseCoordinator: microphoneLeaseCoordinator
        )
        return VoiceConversationComposition(
            resolver: resolver,
            requestMicrophonePermission: LiveSpeechInputComposition.requestMicrophonePermission,
            sleep: { duration in try await Task.sleep(for: duration) },
            reduceMotion: { UIAccessibility.isReduceMotionEnabled },
            telemetry: telemetry,
            presentationCopy: .singleGreenDemo,
            monotonicNow: monotonicNow
        ).dependencies
    }
}

enum AIServiceComposition {
    @MainActor
    static func makeCredentialProvider(
        settings: AISettings
    ) -> any ConversationCredentialProvider {
        #if INTERNAL_DEMO_CREDENTIALS
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
        #if INTERNAL_DEMO_CREDENTIALS
        if settings.buildPolicy.allowsDemoCredentialStorage {
            return DemoSpeechCredentialProvider(settings: settings)
        }
        #endif
        return FailClosedSpeechCredentialProvider()
    }
}
