// M13-PR1 compatibility bridge: existing consumers can continue importing
// LLMKit while provider-neutral contracts and agent semantics live separately.
@_exported import AgentCore
@_exported import LLMCore

extension LLMChatClient: LLMChatTransport {}

public extension LLMAgent {
    /// Retains source compatibility for callers that still construct the concrete client here.
    @available(*, deprecated, renamed: "init(transport:executor:config:)")
    init(client: LLMChatClient, executor: LLMToolExecutor, config: Config) {
        self.init(transport: client, executor: executor, config: config)
    }
}
