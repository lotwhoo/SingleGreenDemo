@_exported import ASRSupervision

extension ASRSession: SupervisedASRSession {}
extension VoiceActivatedASRSession: SupervisedVoiceActivatedASRSession {}

public extension ASRSessionSupervisor {
    /// Builds a fresh concrete provider session for every admitted attempt. The recovery policy is
    /// still explicit so App composition cannot silently invent retry counts or feature fallback.
    init(
        config: ASRSession.Config,
        policy: ASRSessionRecoveryPolicy
    ) {
        self.init(policy: policy) {
            ASRSession(config: config)
        }
    }
}
