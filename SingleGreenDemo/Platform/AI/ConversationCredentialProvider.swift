import Foundation

struct ConversationCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let speechAPIKey: String
    let llmAPIKey: String
    let searchAPIKey: String
    let agentAccountScope: ConversationAgentAccountScope
    let expiresAt: Date

    func isUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        isSpeechUsable(at: date, minimumRemainingLifetime: minimumRemainingLifetime)
            && isLLMUsable(at: date, minimumRemainingLifetime: minimumRemainingLifetime)
    }

    /// ASR-only experiences must not be blocked by an unrelated LLM credential.
    func isSpeechUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        isCurrent(at: date, minimumRemainingLifetime: minimumRemainingLifetime)
            && !speechAPIKey.trimmed.isEmpty
    }

    /// LLM-only experiences must not be blocked by an unrelated ASR credential.
    func isLLMUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        isCurrent(at: date, minimumRemainingLifetime: minimumRemainingLifetime)
            && !llmAPIKey.trimmed.isEmpty
    }

    /// Search tool execution is an independent capability. It must not require
    /// either an ASR or an LLM secret to be present in the same lease.
    func isSearchUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        isCurrent(at: date, minimumRemainingLifetime: minimumRemainingLifetime)
            && !searchAPIKey.trimmed.isEmpty
    }

    /// The provider caches the lease envelope; each consumer validates only the
    /// capability secret it actually needs.
    func isCurrent(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumRemainingLifetime
            && !agentAccountScope.opaqueID.trimmed.isEmpty
    }

    var description: String {
        "ConversationCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

protocol ConversationCredentialProvider: Sendable {
    func lease() async throws -> ConversationCredentialLease
}

/// Least-privilege credential envelope for ASR-only experiences. It cannot
/// expose LLM, search, or Agent account data to the teleprompter composition.
struct SpeechCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let apiKey: String
    let expiresAt: Date

    func isUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumRemainingLifetime
            && !apiKey.trimmed.isEmpty
    }

    var description: String {
        "SpeechCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

protocol SpeechCredentialProvider: Sendable {
    func speechLease() async throws -> SpeechCredentialLease
}

#if DEBUG
@MainActor
final class DemoKeychainCredentialProvider: ConversationCredentialProvider {
    private let settings: AISettings

    init(settings: AISettings) {
        self.settings = settings
    }

    func lease() async throws -> ConversationCredentialLease {
        ConversationCredentialLease(
            speechAPIKey: settings.speechAPIKey,
            llmAPIKey: settings.llmAPIKey,
            searchAPIKey: settings.bochaAPIKey,
            agentAccountScope: try settings.demoLLMAccountScope(),
            expiresAt: .distantFuture
        )
    }
}

@MainActor
final class DemoSpeechCredentialProvider: SpeechCredentialProvider {
    private let settings: AISettings

    init(settings: AISettings) {
        self.settings = settings
    }

    func speechLease() async throws -> SpeechCredentialLease {
        SpeechCredentialLease(
            apiKey: settings.speechAPIKey,
            expiresAt: .distantFuture
        )
    }
}
#endif

protocol ServerCredentialTransport: Sendable {
    func fetchLease() async throws -> ConversationCredentialLease
}

enum ServerCredentialError: Error, Equatable, Sendable, CustomStringConvertible {
    case transportNotConfigured
    case expiredLease

    var description: String {
        switch self {
        case .transportNotConfigured: "ServerCredentialError.transportNotConfigured(redacted)"
        case .expiredLease: "ServerCredentialError.expiredLease(redacted)"
        }
    }
}

struct FailClosedServerCredentialTransport: ServerCredentialTransport {
    func fetchLease() async throws -> ConversationCredentialLease {
        throw ServerCredentialError.transportNotConfigured
    }
}

struct FailClosedSpeechCredentialProvider: SpeechCredentialProvider {
    func speechLease() async throws -> SpeechCredentialLease {
        throw ServerCredentialError.transportNotConfigured
    }
}

actor ServerIssuedCredentialProvider: ConversationCredentialProvider {
    private let transport: any ServerCredentialTransport
    private let now: @Sendable () -> Date
    private let minimumRemainingLifetime: TimeInterval
    private let onJoinInFlight: @Sendable () -> Void
    private var cached: ConversationCredentialLease?
    private var inFlight: Task<ConversationCredentialLease, Error>?

    init(
        transport: any ServerCredentialTransport,
        now: @escaping @Sendable () -> Date = { .now },
        minimumRemainingLifetime: TimeInterval = 30,
        onJoinInFlight: @escaping @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.now = now
        self.minimumRemainingLifetime = minimumRemainingLifetime
        self.onJoinInFlight = onJoinInFlight
    }

    func lease() async throws -> ConversationCredentialLease {
        if let cached, cached.isCurrent(at: now(), minimumRemainingLifetime: minimumRemainingLifetime) {
            return cached
        }
        if let inFlight {
            onJoinInFlight()
            return try await inFlight.value
        }
        let transport = transport
        let now = now
        let minimumRemainingLifetime = minimumRemainingLifetime
        let task = Task {
            let lease = try await transport.fetchLease()
            guard lease.isCurrent(
                at: now(),
                minimumRemainingLifetime: minimumRemainingLifetime
            ) else {
                throw ServerCredentialError.expiredLease
            }
            return lease
        }
        inFlight = task
        defer { inFlight = nil }
        let lease = try await task.value
        cached = lease
        return lease
    }
}
