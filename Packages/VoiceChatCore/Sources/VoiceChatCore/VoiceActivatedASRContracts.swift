import Foundation
import VoiceActivityDetectionKit

public struct VoiceActivatedASRPolicy: Equatable, Sendable {
    public let segmentation: VADSegmentationPolicy
    public let noSpeechFrameLimit: Int
    public let maximumPendingUploadFrameCount: Int
    public let uploadBatchFrameCount: Int

    public init(
        segmentation: VADSegmentationPolicy,
        noSpeechFrameLimit: Int,
        maximumPendingUploadFrameCount: Int,
        uploadBatchFrameCount: Int
    ) throws {
        guard noSpeechFrameLimit >= segmentation.onsetWindowFrameCount else {
            throw VoiceActivatedASRPolicyError.noSpeechFrameLimitTooSmall
        }
        guard maximumPendingUploadFrameCount >= segmentation.preRollFrameCount else {
            throw VoiceActivatedASRPolicyError.pendingUploadLimitTooSmall
        }
        guard (1 ... maximumPendingUploadFrameCount).contains(uploadBatchFrameCount) else {
            throw VoiceActivatedASRPolicyError.uploadBatchFrameCountOutOfRange
        }
        self.segmentation = segmentation
        self.noSpeechFrameLimit = noSpeechFrameLimit
        self.maximumPendingUploadFrameCount = maximumPendingUploadFrameCount
        self.uploadBatchFrameCount = uploadBatchFrameCount
    }

    public static let standard: VoiceActivatedASRPolicy = {
        let segmentation = try! VADSegmentationPolicy(
            preRollFrameCount: 15,
            onsetWindowFrameCount: 5,
            onsetRequiredSpeechFrameCount: 3,
            endpointSilenceFrameCount: 40,
            maximumSegmentFrameCount: 1_000
        )
        return try! VoiceActivatedASRPolicy(
            segmentation: segmentation,
            noSpeechFrameLimit: 750,
            maximumPendingUploadFrameCount: 250,
            uploadBatchFrameCount: 10
        )
    }()
}

public enum VoiceActivatedASRPolicyError: Error, Equatable, Sendable {
    case noSpeechFrameLimitTooSmall
    case pendingUploadLimitTooSmall
    case uploadBatchFrameCountOutOfRange
}

public enum VoiceActivatedEndpointReason: Equatable, Sendable {
    case silence
    case maximumDuration
    case manual
}

public enum VoiceActivatedASRState: Equatable, Sendable {
    case idle
    case arming
    case armed
    case openingRecognizer
    case streaming
    case draining(VoiceActivatedEndpointReason)
    case finalizing(VoiceActivatedEndpointReason)
    case finished
    case failed(ASRFailure)
}

public enum VoiceActivatedASREvent: Equatable, Sendable {
    case state(VoiceActivatedASRState)
    case transcript(String)
    case utterance(String)
    case level(Float)
    case noSpeech
}

public enum VoiceActivatedASRSessionError: Error, Equatable, Sendable {
    case busy
}

enum VoiceActivatedASRCleanupWaitPhase: Equatable, Sendable {
    case willAwait
    case didAwait
}
