import Foundation

struct ConversationCredentialLease: Equatable, Sendable, CustomStringConvertible {
    let speechAPIKey: String
    let llmAPIKey: String
    let searchAPIKey: String
    let agentAccountScope: ConversationAgentAccountScope
    let expiresAt: Date

    func isUsable(at date: Date, minimumRemainingLifetime: TimeInterval = 30) -> Bool {
        expiresAt.timeIntervalSince(date) > minimumRemainingLifetime
            && !speechAPIKey.trimmed.isEmpty
            && !llmAPIKey.trimmed.isEmpty
            && !agentAccountScope.opaqueID.trimmed.isEmpty
    }

    var description: String {
        "ConversationCredentialLease(redacted, expiresAt: \(expiresAt.ISO8601Format()))"
    }
}

protocol ConversationCredentialProvider: Sendable {
    func lease() async throws -> ConversationCredentialLease
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
        if let cached, cached.isUsable(at: now(), minimumRemainingLifetime: minimumRemainingLifetime) {
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
            guard lease.isUsable(
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
