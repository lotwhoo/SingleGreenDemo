// M13-PR2 compatibility bridge: existing consumers can continue importing
// LLMKit while Core, Agent, model transport, and search adapter live separately.
@_exported import AgentCore
@_exported import BochaSearchAdapter
@_exported import LLMCore
@_exported import OpenAICompatibleTransport

public extension LLMAgent {
    /// Retains source compatibility for callers that still construct the concrete client here.
    @available(*, deprecated, renamed: "init(transport:executor:config:)")
    init(client: LLMChatClient, executor: LLMToolExecutor, config: Config) {
        self.init(transport: client, executor: executor, config: config)
    }
}
