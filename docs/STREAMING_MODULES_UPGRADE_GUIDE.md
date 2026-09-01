# 流式文本与 LLMKit 模块化升级指南

> 状态：当前可复用基线
>
> 更新日期：2026-08-29
> 适用范围：`StreamingTextKit`、`LLMKit`、AI Conversation App Adapter

## 1. 本次审阅结论

原有流式功能的正确性已有完整测试，但有两个结构性耦合：

1. 打字节奏、Unicode 增量对齐和自动跟随策略分散在 App Controller 与 SwiftUI Renderer 中，难以在其他 Experience 或 App 中复用。
2. `LLMAgent` 直接依赖 `LLMChatClient`，替换供应商或使用本地/测试传输时必须经过 HTTP 客户端。

本次采用最小重构，不改变状态机、SSE 语义、HUD 布局、默认 33ms 节奏、15 tick 追平、Reduce Motion 或错误行为。

## 2. 最终依赖方向

```text
VoiceConversationController
    │
    ├── Conversation ports
    │     ├── SpeechRecognitionSession
    │     └── ConversationAgent
    │
    ├── StreamingTextKit
    │     ├── TypewriterPolicy
    │     ├── TypewriterTextBuffer
    │     ├── StreamingTextReconciler
    │     └── StreamingTextAutoFollowPolicy
    │
    └── Live adapters
          ├── VoiceChatCore
          └── LLMKitConversationAgent
                  └── LLMAgent
                          └── LLMChatTransport
                                  └── LLMChatClient / 其他供应商
```

规则：App Controller 只编排状态；算法进入 `StreamingTextKit`；供应商差异进入 Transport 或 Live Adapter。

## 3. StreamingTextKit 公共接口

### `TypewriterPolicy`

控制 tick 周期、短/中积压阈值、批量和目标追平 tick 数。默认 `.standard` 与当前真机验收行为一致。

```swift
let fasterPolicy = TypewriterPolicy(
    tickIntervalMilliseconds: 20,
    shortBacklogLimit: 8,
    mediumBacklogLimit: 24,
    mediumBatchSize: 3,
    minimumLargeBatchSize: 5,
    catchUpTickBudget: 10
)
```

在 App 中通过 `VoiceConversationDependencies.streamingTextPolicy` 注入，不要在 Controller 中增加新的硬编码节奏。

### `TypewriterTextBuffer`

- `append(_:)`：追加上游增量。
- `advance(maxCharacters:)`：仅在完整 Swift `Character` 边界前进。
- `suggestedBatchSize()`：根据积压和 policy 返回本 tick 批量。
- `flush()`：Reduce Motion 或失败保留 partial 时直接追平。
- `reset()`：清理文本，保留注入的 policy。

### `StreamingTextReconciler`

按 Unicode scalar 校验增量前缀并取最终后缀。禁止改回 `String.hasPrefix` + `dropFirst(Character.count)`，否则 base character 与 combining mark 跨 SSE delta 时会误判。

### `StreamingTextAutoFollowPolicy`

仅在内容高度增长并超过 viewport 时返回 `true`。SwiftUI View 负责测量与执行滚动，纯策略保持无 UI 状态、可单测。

## 4. LLMKit SSE 稳定接口

### `LLMChatTransport`

Transport 只需提供两个语义操作：

```swift
public protocol LLMChatTransport: Sendable {
    func completeMessage(...) async throws -> LLMMessage
    func completeMessageStreaming(...) -> AsyncThrowingStream<LLMStreamingEvent, Error>
}
```

`LLMAgent` 只依赖该协议。默认 `LLMChatClient` 位于独立 `OpenAICompatibleTransport` 模块并实现 OpenAI 兼容 HTTP + SSE；本地模型、WebSocket 供应商、网关或测试 Stub 可以直接实现 Transport。博查工具执行器位于独立 `BochaSearchAdapter`；新代码直接依赖窄产品，`LLMKit` 仅用于旧调用方兼容。

旧 `LLMAgent(client:executor:config:)` 构造器保留为 deprecated 兼容层；新代码使用：

```swift
let agent = LLMAgent(
    transport: providerTransport,
    executor: toolExecutor,
    config: configuration
)
```

### 不可破坏的 SSE 约束

1. 只消费首个观察到的目标 choice。
2. 仅目标 `finish_reason` 或全局 `[DONE]` 表示完成。
3. 已发布内容后失败不自动重试，避免重复文本。
4. tool call 按 index 组装，id/name 不完整必须失败。
5. Agent 仅在最终回答完成时提交上下文；取消、Reset、新事务和工具失败不得提交。
6. 非规范 content → tool mixed 输出会立即撤销 durable partial。若要求严格零瞬时展示，只能牺牲真实首 token 流式并缓冲整轮。

## 5. 文件边界

| 文件 | 职责 |
| --- | --- |
| `ConversationPorts.swift` | App 端 ASR/Agent 稳定合同与配置快照 |
| `ConversationDependencies.swift` | App live entry；调用共享 resolver/composition，不承载 provider 细节 |
| `VoiceConversationComposition.swift` | App-internal composition；接收一个 shared resolver，输出四组核心依赖 |
| `ConversationPreparationResolver.swift` | 独占 settings-derived input、ASR 与 Agent preparation；`AgentFactory` 仅 internal test seam |
| `ConversationCredentialProvider.swift` | credential lease/provider 与 fail-closed server boundary |
| `ConversationPresentationPolicy.swift` | App presentation copy policy |
| `ConversationTelemetryStore.swift` | App telemetry sink/store |
| `ProductionVoiceActivatedSessionFactory.swift` | App-owned inactive VAD/ASR production factory |
| `ConversationLiveAdapters.swift` | VoiceChatCore / LLMKit 生产适配 |
| `VoiceConversationController.swift` | 会话状态与取消编排 |
| `HUDFlowingTextView.swift` | SwiftUI 测量、样式、尾部 anchor 执行 |

Controller 不得直接 import `LLMKit` 或 `VoiceChatCore`；Live Adapter 不得修改 Domain/HUD 状态。

## 5.1 M8 dependency and composition contract

`VoiceConversationDependencies` now groups four public immutable values: `input`, `agent`, `presentation`, and `observability`. New callers should use the grouped initializer. The previous flat initializer and its 11 accessors remain for source-package compatibility; they do not promise binary layout or ABI stability. The Controller still owns its Task handles, generation checks, cancellation, session lifecycle, reply identity, and display scheduling.

The App composition root keeps `ConversationDependencies.swift` intentionally small. `VoiceConversationComposition` receives one shared `ConversationPreparationResolver`; that resolver exclusively derives settings-dependent input mode, ASR preparation, and Agent behavior. This makes an A/B misassembly (for example, settings from one composition with an Agent from another) structurally harder and is covered by composition tests. The internal `AgentFactory` exists only as a deterministic test seam and must not become a public extension point.

Do not introduce a Service Locator, global registry, or runtime hot swap for this boundary. Consider splitting LLMKit only when a second independently shipped transport/provider SDK/platform consumer creates a stable ownership boundary. Consider an Experience/Provider Registry only after a real runtime switching requirement exists, at least two production implementations are available, and lifecycle/context semantics are specified.

## 6. 后续升级检查表

### 调整打字效果

1. 优先新建 `TypewriterPolicy`，不修改 buffer 算法。
2. 使用 40/120/200 字、emoji、ZWJ、combining scalar 复测。
3. 确认 Reduce Motion 仍直接 flush。
4. 确认渲染发布不高于目标 tick 频率。

### 替换 LLM 供应商

1. 实现 `LLMChatTransport`，统一输出 `LLMStreamingEvent`。
2. 保留完成标记、取消传播和已输出后不重试语义。
3. 工具定义仍通过 `LLMToolExecutor`，不将搜索逻辑写入 Transport。
4. 在 `ConversationLiveAdapters.swift` 切换生产实现，Controller 不改动。
5. 使用 Stub Transport 验证 Agent，再增加供应商网络契约测试。

## 7. 验证命令

```bash
cd Packages/StreamingTextKit && swift test
cd Packages/LLMKit && swift test
cd Packages/VoiceChatDomain && swift test
cd Packages/VoiceChatCore && swift test
swift test
xcodebuild -project SingleGreenDemo.xcodeproj -scheme SingleGreenUser -configuration User-Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

当前基线：156 项自动化测试通过，App-hosted XCTest、arm64 + x86_64 Simulator build、Apple Development 签名的 iphoneos arm64 build 均通过。用户已确认现有真机功能测试成功；真实服务供应商变更、不同网络环境和辅助功能仍应在每次发布前回归。
