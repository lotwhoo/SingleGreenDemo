# 功能任务卡：AI 流式回答 HUD、打字机与自动上翻

状态：真机功能验收通过，模块化升级完成

负责人：主 Agent

创建日期：2026-08-27

## 1. 原始需求

> 利用我们的 Agent，新做一个功能：修改单绿眼镜上 AI 回答的 UI 显示区域，使其合理，充分利用流式返回的效果，并具有打字机效果和自动上翻效果。

## 2. 问题与目标用户

- 目标用户：通过单绿眼镜或当前手机模拟 HUD，以语音快速获取 AI 回答的用户。
- 使用场景：用户仍需关注真实环境，希望从首个增量开始连续阅读，不进行频繁手动操作。
- 当前问题：AI 回答区仅占 HUD 安全区高度的 28%，通用 detail 文本强制最多两行并居中、允许缩小到 62%；长回答会缩小或截断。
- 链路问题：`LLMChatClient` 已支持普通文本 SSE，但生产路径 `ConversationAgent → LLMAgent.send()` 仍等待完整字符串，HUD 无法显示真实增量。
- 期望结果：真实 LLM 增量进入 Controller 后，以稳定字号、字素安全的打字机节奏显示；正文溢出时自动上翻，并保持最新行可见。

## 3. 范围

### 本次目标（P0）

- 打通生产 LLM SSE 到 `ConversationAgent`、`VoiceConversationController` 和 HUD。
- 支持普通回答以及联网工具调用后的最终回答流式输出。
- pending assistant message 按 reply UUID 累计更新，继续隔离旧任务和新会话。
- 网络增量与显示节奏解耦；按 Swift `Character` 边界显示，不拆分 emoji 或组合字符。
- 提供可取消、可注入时钟的打字机队列；基础速度约 20–40ms/字素，积压时自适应追平。
- AI 回答使用专用 HUD 内容和 Renderer：左对齐、固定可读字号、不缩字、至少占 safeRect 高度的 55%，目标 Profile 至少显示 5 行。
- 正文溢出时自动跟随尾部并按视觉行上翻；高频更新合并到不高于 30Hz。
- 覆盖 thinking、searching、streaming、completed、partial failure、empty、cancel/reset 状态。
- 流中失败时保留已显示的部分文本并标记“回答中断”，但不得写入 Agent completed 上下文。
- 更新 README 与架构报告中的 AI 数据流说明。

### 明确非目标（P1）

- 手动上滑回看、暂停自动跟随或完整历史浏览。
- Markdown、代码高亮、表格、图片和引用卡片。
- 用户自定义字体、打字速度、行数或动画曲线。
- TTS 同步、逐词高亮或语音播报。
- 修改 ASR、VAD、联网搜索策略或系统回答长度策略。
- 本期不完成真实光学眼镜的专项标定；P0 仅以 `simulator.default.v2` 和真机手机预览验收。

## 4. 用户故事

```text
作为单绿眼镜用户，
我希望 AI 一开始生成就看到文字，并在内容增长时自动上翻，
从而无需等待整段回答或手动滚动，也能连续阅读最新内容。
```

## 5. 默认产品与 UX 决策

- 回答开始后使用紧凑状态栏；用户问题最多两行，AI 正文成为主区域。
- 回答区目标约占 safeRect 高度 60%，正文左对齐，保留语义换行，不持续显示“AI：”。
- 网络层立即累计真实文本；展示层从缓冲区平滑取出完整字素。
- 首个 delta 到达后目标 150ms 内出现首字；积压过多时每 tick 显示多个字素，持续落后不超过 1 秒。
- 内容未溢出时保持顶部稳定；形成新视觉行并溢出时自动跟随尾部，完成后保持尾部，不回跳开头。
- Reduce Motion 开启时不逐字播放和闪烁，直接按增量追加并使用无动画跟随。
- P0 不提供手动暂停跟随；完整回答仍保存在领域状态，为 P1 回看能力保留数据。
- 流中失败或取消时保留已显示部分并标记未完成；开始新会话或 Reset 时清空旧展示状态。

## 6. 验收标准

### AC-1：真实增量进入 App

```text
Given Fake Agent 依次产生“你”“好”“，”“世界”
When Controller 消费每个 delta
Then pending 回复按顺序累计为“你”“你好”“你好，”“你好，世界”，而不是完成后一次性出现
```

### AC-2：字素安全与完整性

```text
Given delta 包含中文、英文、换行和组合 emoji
When 打字机逐步展示并正常完成
Then 每一帧都结束在 Character 边界，最终文本与所有 delta 顺序拼接结果完全一致，无丢失、重复或重排
```

### AC-3：首字与追平

```text
Given 状态为 thinking 且收到首个有效 delta
When 展示时钟推进一个周期
Then HUD 进入“回答中”并显示首字；目标设备从收到 delta 到首字更新不超过 150ms
```

- 默认节奏约 20–40ms/字素；积压时允许批量追平。
- 展示落后不得持续超过 1 秒；上游完成后剩余缓冲应在 500ms 内追平。

### AC-4：回答区域与自动上翻

```text
Given simulator.default.v2 且回答超过可见行数
When 新文本形成下一条视觉行
Then 回答视口高度不低于 safeRect 的 55%，正文左对齐且不缩字；最新完整行和生成行持续可见，旧行稳定向上移出
```

- 正常字号下至少完整显示 5 行。
- 40、120、200 字中文及中英混排、emoji、显式换行均不越界。
- 场景/渲染更新合并到不高于 30Hz，不能随每个字符抖动或反向跳动。

### AC-5：搜索、失败和空回答

```text
Given Agent 触发 web_search
When 搜索未完成
Then HUD 只显示搜索态，不显示伪回答
When 最终回答首个 delta 到达
Then 搜索提示被真实正文替换并开始打字机显示
```

- 流产生部分文本后失败：保留部分正文，停止光标并显示“回答中断，请重试”；不得标为 completed。
- 流未产生有效文本即完成：进入 failed，显示空回答错误，不创建 completed 空消息。

### AC-6：取消、Reset 与竞态隔离

```text
Given 回复 A 正在流式输出
When 用户开始问题 B、执行 Reset 或切换 Experience
Then A 的网络任务和打字任务被取消，之后到达的 A delta 不得改变 B 的文本、状态、revision 或滚动位置
```

- Runtime 即使通过 `bufferingNewest(1)` 合并中间快照，下一份快照也必须携带完整累计前缀，最终不丢字。

### AC-7：完成态与辅助功能

- 上游正常完成且展示队列追平后，回复才标记 completed，光标消失，正文保持尾部窗口且不再变化。
- Reduce Motion 下无逐字动画、闪烁或滚动动画。
- VoiceOver 不逐 token 播报；状态变化播报一次，完成回答可作为整体读取。

## 7. 当前代码路径

```text
AIConversationExperience
→ VoiceConversationController.requestReply
→ ConversationAgent / LLMKitConversationAgent
→ LLMAgent.send（当前非流式）
→ LLMChatClient.completeMessage
→ ConversationState.completeReply
→ ConversationHUDMapper
→ HUDScene
→ ExperienceSnapshot
→ ExperienceRuntime
→ HUDOverlayView（当前 detail 最多 2 行）
```

已有可复用能力：

- `LLMChatClient.completeStreaming` 的 SSE 文本增量与网络测试。
- `ExperienceSession.updates()`、累计 `ExperienceSnapshot` 和 Runtime 旧 Session 隔离。
- `ConversationState` 的 reply UUID 与 Controller 的 reply generation。

## 8. 预计修改边界

- `Packages/LLMKit/Sources/LLMKit/Models.swift`
- `Packages/LLMKit/Sources/LLMKit/LLMChatClient.swift`
- `Packages/LLMKit/Sources/LLMKit/LLMAgent.swift`
- `Packages/LLMKit/Tests/LLMKitTests/*`
- `Packages/VoiceChatDomain/Sources/VoiceChatDomain/ConversationState.swift`
- `Packages/VoiceChatDomain/Tests/VoiceChatDomainTests/ConversationStateTests.swift`
- `SingleGreenDemo/Platform/AI/ConversationDependencies.swift`
- `SingleGreenDemo/Platform/AI/VoiceConversationController.swift`
- `SingleGreenDemo/Platform/AI/ConversationHUDMapper.swift`
- `SingleGreenDemo/Platform/Domain/HUDScene.swift`
- `SingleGreenDemo/Platform/Rendering/HUDOverlayView.swift`
- 可能新增可独立测试的打字机/展示模型与专用回答 View。
- `SingleGreenDemoTests/VoiceConversationControllerTests.swift`
- `SingleGreenCoreTests/SingleGreenCoreTests.swift`
- `README.md`
- `docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md`

精确文件和接口由 `ios_architect` 在任务卡确认后确定。

## 9. 测试矩阵

| 编号 | 层级 | 场景 | 预期结果 |
|---|---|---|---|
| T-1 | LLMKit 单元 | SSE content 与 tool call delta 拼装 | 内容和工具参数顺序、完成消息正确 |
| T-2 | LLMKit 单元 | 工具调用后最终回答流式输出 | 搜索状态后产生真实正文增量，上下文事务正确 |
| T-3 | Domain 单元 | pending 回复按 UUID 追加 delta | 旧 ID 无效，完成/失败/取消语义正确 |
| T-4 | App 单元 | Fake delta + Fake 时钟 | 字素安全、节奏、追平和 completed 时机正确 |
| T-5 | App 单元 | Reset/打断/旧 delta | 旧回复无法污染新会话 |
| T-6 | App 单元 | partial failure / empty stream | 保留部分展示但不提交上下文，空回答失败 |
| T-7 | Mapper/Core | AI 专用视口几何 | 回答区 ≥ 55%，所有元素位于 safeRect |
| T-8 | Renderer/手工 | 40/120/200 字、emoji、换行 | 固定字号、至少 5 行、稳定自动上翻 |
| T-9 | Runtime 集成 | 高频累计快照 | `bufferingNewest(1)` 合并后最终不丢字 |
| T-10 | 回归 | 当前全部单元测试 | 现有 116 项全部通过，新增测试全部通过 |
| T-11 | iOS Build | Simulator 与 iphoneos arm64 | 构建通过，无新增 Swift 并发错误 |
| T-12 | 真机手工 | 相机背景下真实 ASR/LLM/Search | 首字、打字机、自动上翻、打断和错误态符合验收标准 |

## 10. 风险、依赖与开放问题

- 最大风险是“工具调用 + SSE”：当前 chunk 只解析 `delta.content`，架构方案必须明确 tool call delta 的拼装与兼容行为。
- SwiftUI 实际换行依赖字体、宽度和字素，不能用固定字符数估算视觉行。
- 每字重建整个 `HUDScene` 会造成布局压力；需要累计前缀和节流发布，不能丢失中间字符。
- 部分回答展示与 Agent completed 上下文必须分离，避免失败片段污染后续多轮对话。
- 真眼镜与手机模拟 Profile 的可视行数不同；真实光学标定留到 P1，但完成后应在当前真机预览做手工验收。

等待用户确认的默认决策：

1. P0 做真实 SSE，不接受仅对完整答案播放的“假流式”。
2. 完成后保持尾部，不自动回到开头。
3. P0 不做手动回看；后续 P1 再增加上滑暂停和下滑恢复跟随。
4. 中途失败保留部分显示，但不写入 completed Agent 上下文。
5. 保留当前“一般不超过 200 字”的系统提示，同时用 200 字做布局验收。

## 11. 阶段交接

### Research / Product / UX → Architecture

- 事实：底层已有普通文本 SSE；生产 Agent、Domain pending 回复和 HUD 尚未接通真实增量。
- 已建议范围：真实流式、专用回答视口、字素安全打字机、自动尾随、失败/取消与测试。
- 禁止捷径：不能通过全局放宽 `.detail` 行数影响所有 Experience；不能仅对最终完整字符串做动画后宣称真实流式。
- 下一阶段：用户确认本任务卡后，由 `ios_architect` 给出接口、并发/取消、工具调用 SSE 和精确文件方案。

### Architecture → Implementation

- LLM Transport：新增同时承载 `contentDelta`、`toolCallDelta` 和 completed message 的 SSE 事件；工具片段按 index 聚合，保留现有非流式 API 兼容。
- Agent：新增流式发送接口；每轮保持原有上下文事务，工具轮不向 UI 泄露正文，最终无工具回答才提交上下文；失败、取消或混合正文/工具异常均回滚。
- Domain：pending 回复支持按 UUID 追加 delta，并增加 streaming 状态；部分失败保留 failed 文本，取消/Reset 移除 active partial。
- Controller：网络累计与可见文本分层；新增纯值字素缓冲和独立 typing task，约 33ms 发布一次，积压时批量追平；reply UUID 与 generation 同时保护所有事件和定时 tick。
- HUD：新增专用流式文本内容，回答区使用 `x=.08, y=.35, width=.84, height=.61`；Renderer 通过真实内容高度和 tail anchor 自动上翻，不改变其他 detail 元素。
- 新增文件：`Platform/AI/TypewriterTextBuffer.swift`、`Platform/Rendering/HUDFlowingTextView.swift`。
- 实现顺序：Transport → Agent → Domain → 字素缓冲 → Controller → Mapper/Renderer → 文档 → 分层测试与全量回归。

## 12. 验证记录

| 命令/操作 | 结果 | 日期 |
|---|---|---|
| Researcher / Product Planner / UX Designer 只读分析 | 完成 | 2026-08-27 |
| 任务卡用户确认 | 已确认 | 2026-08-27 |
| iOS Architect 技术设计 | 完成 | 2026-08-27 |
| 修改前 Package 基线 | 94 项通过 | 2026-08-27 |
| 修改前 App-hosted XCTest 基线 | 22 项通过 | 2026-08-27 |
| 受影响 Package 测试 | 未运行 |  |
| `bash` 全量测试 | 未运行 |  |
| iOS Simulator Build | 未运行 |  |
| 真机真实服务验证 | 未运行 |  |

### Implementation → Test

- 已实现：`LLMChatClient.completeMessageStreaming` 解析 content/tool_call delta 并拼装 completed message；`LLMAgent.sendStreaming` 以事务方式执行工具轮和最终回答。
- 已实现：Domain 按 reply UUID 累加 pending delta，部分失败保留 failed 文本，空失败仍移除占位。
- 已实现：Controller 分离网络/可见文本，以 `TypewriterTextBuffer` 按 Character 输出，约 33ms tick 合并 HUD 更新，并同时校验 reply UUID 和 generation。
- 已实现：AI 专用 `flowingText` 元素、61% 高度回答区、固定字号左对齐、尾部自动上翻和 Reduce Motion/VoiceOver 行为。
- 已添加测试：SSE 工具分片、搜索后最终回答流、pending/partial failure、字素完整性、Controller 完成时机、Reset 迟到事件和 HUD 几何。
- 回归修复：流式完成与 typing 追平同 tick 时，改为请求内局部 completion 标记，避免误判 incomplete stream。

| 命令/操作 | 结果 | 日期 |
|---|---|---|
| `swift test`（`Packages/LLMKit`） | 47 项通过 | 2026-08-27 |
| `swift test`（`Packages/VoiceChatDomain`） | 12 项通过 | 2026-08-27 |
| `xcodebuild ... generic/platform=iOS Simulator ... build CODE_SIGNING_ALLOWED=NO` | 通过 | 2026-08-27 |
| `xcodebuild ... iPhone 17 Pro ... test -only-testing:SingleGreenDemoTests` | 27 项通过 | 2026-08-27 |
| 真机真实 ASR/LLM/Search | 未执行，交给 Test/Release 阶段 | 2026-08-27 |

### Test Engineer 独立验收

- 首轮 App-hosted 回归发现 4 个失败用例：2 个是测试命令禁用模拟器签名导致 Keychain 不可用；2 个暴露打字机追平批量会逐 tick 衰减，无法在 15 tick 内追平。
- 已修正：一次积压期间保持自适应批量预算；纯空格/换行流不再保留为 partial；HUD 不再每字触发滚动动画，仅内容高度实际增长且溢出视口时跟随尾部。
- 所有测试使用 URLProtocol / Fake Agent / Fake ASR / 可控时钟，未使用真实 API Key 或外网。

| 命令/操作 | 结果 | 日期 |
|---|---|---|
| `swift test`（顶层 SingleGreenCore） | 15 项通过 | 2026-08-27 |
| `swift test`（`Packages/VoiceChatDomain`） | 13 项通过 | 2026-08-27 |
| `swift test`（`Packages/VoiceChatCore`） | 25 项通过 | 2026-08-27 |
| `swift test`（`Packages/LLMKit`） | 51 项通过 | 2026-08-27 |
| App-hosted XCTest（签名 iPhone 17 Pro Simulator） | 35 项通过 | 2026-08-27 |
| 自动化测试合计 | **139 项通过，0 失败** | 2026-08-27 |
| generic iOS Simulator build（arm64 + x86_64） | `BUILD SUCCEEDED` | 2026-08-27 |

仍需人工/真机验证：40/120/200 字在真实相机背景上的可读性与视觉行稳定性；真实 ASR → LLM → Bocha Search 首字时延；VoiceOver 播报频率；Reduce Motion 的系统级视觉验收。

### Reviewer No-Go 定点修复与复验

- `LLMChatClient` 只消费首个观察到的目标 choice；目标 choice 的 `finish_reason` 或全局 `[DONE]` 才视为完成。正文后连接直接关闭会抛出 `incompleteStream`，其他 choice 的正文与结束原因均不进入结果。
- `LLMAgent` 的同步和流式请求共用 generation/active transaction 保护。`clearContext()` 或新请求会使旧事务失效，旧任务随后不得提交或回滚共享上下文。
- 共享 commit 在紧邻上下文写入前执行任务取消检查；流式事件循环结束后也再次检查。消费者收到 partial 后取消，即使受控服务端随后完成，Agent 上下文仍保持为空。
- 非规范 provider 若先发 content、后发 tool call，为保留真实首 token 流式，伪正文可能瞬时显示；识别 mixed content/tool 后会以 `discardPartial` 语义穿过 App bridge，立即清除 Domain pending、typewriter buffer 和 HUD 文本。若要求严格零瞬时泄漏，就必须缓冲整轮，这与真实首 token 流式目标不能同时保证。
- Controller 的完成补齐按 Unicode scalar 前缀/后缀处理，覆盖 base character 和 combining mark 分处不同事件的情况；无有效 partial 的失败与空 completion 均清空可见文本。

| 命令/操作 | 结果 | 日期 |
|---|---|---|
| `swift test`（`Packages/LLMKit`） | 58 项通过 | 2026-08-27 |
| `swift test`（`Packages/VoiceChatDomain`） | 14 项通过 | 2026-08-27 |
| App-hosted XCTest（签名 iPhone 17 Pro Simulator） | 39 项通过 | 2026-08-27 |
| `swift test`（顶层 Core + `Packages/VoiceChatCore`） | 40 项通过 | 2026-08-27 |
| 自动化测试合计 | **151 项通过，0 失败** | 2026-08-27 |

### Reviewer / Release 最终结论

- Reviewer 复审：`Go`，已关闭全部 P1，未发现新的 P0/P1。
- Test Engineer 最终只读复测：151 项自动化测试全部通过，签名 App-hosted XCTest 与 generic iOS Simulator build 均成功。
- Release Analyst：代码合并 `Go`；真机发布 `No-Go`，等待真实服务、视觉与辅助功能人工验收。
- 签名 device build：`generic/platform=iOS` arm64 构建成功，Apple Development 签名与 provisioning profile 生效；本阶段未安装。

真机发布前仍需验证：真实 ASR → LLM → Bocha Search；40/120/200 字、中英混排、emoji 与换行的阅读和自动上翻；Reduce Motion；VoiceOver；弱网/断网；首字 150ms 目标与持续追平性能。

## 13. 后续模块化升级记录

用户完成真机功能验证后，在不改变 SSE、打字机、自动上翻、取消和错误语义的前提下完成第二阶段结构重构：

- 新增独立 Swift Package `StreamingTextKit`，统一封装 `TypewriterPolicy`、`TypewriterTextBuffer`、`StreamingTextReconciler` 和 `StreamingTextAutoFollowPolicy`。
- 默认策略仍为 33ms tick、短积压逐字、中积压双字、大积压 15 tick 预算追平；配置构造时会归一化非法边界，公共属性只读，避免运行中破坏策略不变量。
- App AI 层拆分为 `ConversationPorts.swift`、`ConversationLiveAdapters.swift` 和 `ConversationDependencies.swift`。Controller 只依赖稳定协议并负责状态编排，不直接依赖 LLMKit 或 VoiceChatCore。
- LLMKit 新增 `LLMChatTransport` 协议；`LLMAgent` 改为依赖 Transport 抽象。现有 `LLMChatClient` 继续作为默认 OpenAI-compatible HTTP/SSE 实现，并保留旧构造器兼容已有调用方。
- SwiftUI 仍只负责测量内容高度和执行尾部滚动；是否跟随由 `StreamingTextKit` 的纯策略决定。
- 详细接口、供应商替换流程和升级检查表见 `docs/STREAMING_MODULES_UPGRADE_GUIDE.md`。

模块化后自动化基线：

| 测试层 | 数量 | 结果 |
|---|---:|---|
| SingleGreenCore | 15 | 通过 |
| VoiceChatDomain | 14 | 通过 |
| VoiceChatCore | 25 | 通过 |
| LLMKit | 59 | 通过 |
| StreamingTextKit | 7 | 通过 |
| App-hosted XCTest | 36 | 通过 |
| 合计 | **156** | **0 失败** |

此节为第 7、8、11、12 节历史设计与验收记录的现行补充；当前生产路径已经使用真实流式接口和独立 `StreamingTextKit`，不再使用 App 内部的 `TypewriterTextBuffer.swift`。
