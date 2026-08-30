# 单绿测试平台

原生 SwiftUI iOS Demo，用 iPhone 后摄画面模拟环境透视，并叠加可扩展的单绿 HUD Experience。

## 当前完成范围

- Xcode 原生 App 与单元测试 Target。
- iOS 26.0 Deployment Target。
- iPhone 17 Pro Max / iOS 26 作为主要验收环境。
- 后摄权限、预览和无权限替代背景。
- 通用 `DemoEvent → Experience → HUDScene → Renderer` 链路。
- 眼镜核心能力下沉到 `SingleGreenGlassesKit`；App 只作为相机模拟、调试控件和真实服务组装宿主。
- `simulator.default.v2` DisplayProfile。
- 基础状态、导航、通知、字幕/提词四个本地 Experience。
- AI 对话 Experience：完整接入 `VoiceChatDomain`、`VoiceChatCore`、`LLMKit` 与可复用 `StreamingTextKit`，形成豆包流式 ASR → DeepSeek Agent → 按需博查联网搜索 → 字素安全显示链路。
- M6 Stage 2A 已将独立的 `VoiceActivityDetectionKit` 接入录音帧、VAD 门控 ASR、眼镜核心 port 和 App adapter；获用户批准的最小 WebRTC C 闭包已在 `SingleGreenDemo` composition root 接入，factory 仅在生产 root 非空且 arm 后工作，未提供能量检测回退。
- WebRTC 依赖的固定来源、11 upstream C + 1 project compatibility C + 12 upstream headers、隐藏可见性 wrapper、五符号 facade 和许可证边界见 [WebRTC VAD ADR](./docs/tasks/2026-08-28-webrtc-vad-approval-adr.md)；真机已完成用户观察验收，仍待完整脚本化 VAD/ASR/provider 路由与中断矩阵。
- 首页采用全屏相机内容层，状态、调试与控制面板作为悬浮功能层。
- 使用 SwiftUI 原生 Material 与 iOS 26 Liquid Glass：普通内容容器使用标准材质，关键交互按钮使用可交互玻璃效果。
- 原生场景 Menu、悬浮诊断条、三个手势按钮与紧凑的 HUD 显示控制。
- HUD 开关、模拟强度、上滑、点击、下滑和体验重置。
- HUD 模拟显示区域使用约 8:3 可见长宽比，保持水平居中并相对屏幕中心上移 `0.20` 屏高，使其落在顶部栏与下方诊断条之间的视觉中心；顶部标题、设置与 Debug 按钮直接从宿主已提供的安全区起点布局，不重复叠加安全区高度。
- 相机配置与启停在专用队列执行，首屏先显示、后摄异步预热。
- 调试模式显示本次冷启动的相机 Session 启动耗时。

## 长程开发路线

项目按产品设计、架构、实现、测试、评审、文档和发布的完整流程推进。当前 M1–M9 的自动化基础已按下表推进：

| 里程碑 | 目标 | 状态 |
| --- | --- | --- |
| M1 | Canonical AI/Runtime Snapshot：统一 `ExperienceSnapshot`、`currentSnapshot` 兼容入口、原子化去重传播 | 已实现并验证 |
| M2 | Display Profile v2 / Hardware Boundary：分离中立显示参数与 SwiftUI，并建立真实硬件适配边界 | 已实现并完成自动化验证 |
| M3 | Experience Capability Catalog：声明网络、麦克风、相机、后台更新和可用操作 | 已实现并完成自动化验证 |
| M4 | Controller Decomposition / Strict Concurrency：拆分对话控制器并收紧并发隔离 | 已实现并完成自动化验证 |
| M5 | Production Readiness / Release System：CI、设备回归、短期凭证、观测和发布流程 | 自动化基础已实现，人工门禁待完成 |
| M6 | Local VAD / Automatic Endpointing：本地检测、自动端点和 ASR 门控 | WebRTC production detector 已集成并通过本地回归；真机/真实服务门禁待完成 |
| M7 | 纯代码质量：架构边界、工具链、公开 API、生命周期与复用契约 | PR1–PR5 已在本地完成；本检查点完成 |
| M8 | Dependency & Composition Refinement：分组核心依赖、收口 App Composition Root、验证装配隔离 | PR1–PR4 已在本地完成；真机与真实服务门禁待完成 |
| M9 | Runtime State Decomposition：拆分 Controller generation 状态、音频运行态和 VAD/ASR 每轮缓冲状态 | 已实现；受影响 Package 与静态契约已复核，App/真机门禁待完成 |

M7 PR1 的本地证据为六个 Package 严格并发 **377/377**、App XCTest **62/62**、架构边界 10 个负例和 14 个公开 API snapshot 门禁通过；该记录属于历史快照，见 [M7 PR1 任务卡](./docs/tasks/2026-08-28-m7-pr1-quality-baseline.md)。

当前 M7 PR2 已在本地完成 VAD/ASR 生命周期正确性加固：六个 Package 严格并发 **390/390**，其中 `VoiceChatCore` 104 项；App XCTest **62/62**。`VoiceActivatedASRSession` 使用单一可注入单调时钟 watchdog 处理无帧超时，并保留 pre-onset/post-onset finish 与尾部排空契约。完整证据见 [M7 PR2 任务卡](./docs/tasks/2026-08-28-m7-pr2-lifecycle-correctness.md)。GitHub Actions 尚未执行，PR2 未进行真机、真实服务或人工无障碍/光学验收。

M7 PR3 已完成对话适配器的可复用边界；其 **414/414**、适配器 **24/24** 和 **100/100** 重复结果均为历史证据，详见 [M7 PR3 任务卡](./docs/tasks/2026-08-28-m7-pr3-public-reuse-contract.md)。

PR3+PR4 历史合并质量门禁为七个 Package **438/438**（7、16、43、174、24、70、104）、App **55/55**；适配器关键用例重复 **480** 次，终态生命周期用例重复 **380** 次。`ExperienceRuntime.init(validating:)` 为本轮新增的兼容性审查 API。Debug 与严格 universal Release Simulator（arm64+x86_64）构建通过。完整记录见 [M7 PR4 任务卡](./docs/tasks/2026-08-28-m7-pr4-terminal-lifecycle.md)。这是 PR5 之前的历史合并快照；M7 历史序列随后由 PR5 证据补充，当前整体代码检查点则以 M9 为准。

历史兼容标记：PR1、PR2、PR3、PR4 已在本地完成；本检查点完成

M7 PR5 已完成机械拆分：新增内部 `ConversationTelemetryTracker`，并将 `VoiceConversationController` 的测试支持移入独立文件；控制器的任务、generation 和并发所有权保持不变。PR5 四文件隔离复测为 SGK **174/174**、关键用例 **17×20=340/340**、App **55/55**；SGK 覆盖率 **93.91%**，适配器 **98.02%**，16 个 API snapshots byte-identical。完整范围和剩余验证边界见 [M7 PR5 任务卡](./docs/tasks/2026-08-28-m7-pr5-mechanical-decomposition.md)。

为兼容既有文档回归门禁，历史标记保留（已由 PR5 supersede）：最新 PR3+PR4 合并严格证据为七 Package **438/438**；该快照已由本段 PR5 隔离复测补充。

### M8 Dependency & Composition Refinement（本地完成，2026-08-29）

M8 将 `VoiceConversationDependencies` 分为四个公开、不可变依赖组：`input`、`agent`、`presentation` 和 `observability`。原有扁平初始化器与 11 个访问器继续保留，保证 source-package 兼容；这不是对 Swift struct 的二进制布局或 ABI 承诺。`VoiceConversationController` 的 Task、generation、取消、session、reply 和 display 所有权没有改变。

App 的 `ConversationDependencies.swift` 现在只保留 live 入口；其余职责位于五个专门文件。内部 `VoiceConversationComposition` 接收一个共享 `ConversationPreparationResolver`，由 resolver 独占 settings 派生的 input、ASR 和 Agent 行为，避免 A/B 组合误装配。`AgentFactory` 仅是内部测试 seam，不是公共扩展点；当前不引入 Service Locator、全局 Registry 或运行时热切换。

M8 本地证据：`SingleGreenGlassesKit` **178/178**；App XCTest **58/58**；聚焦 `ConversationPreparation` **17/17**；Controller + dependency 回归 **99/99**。八个模块的 16 份 API snapshot 已审查：仅 `SingleGreenGlassesKit` 的 macOS arm64 与 iOS Simulator arm64 两份发生变化，各 **39 additions / 0 removals**。架构门禁覆盖七个 Package 与 11 个负例；Debug/Release generic Simulator build 通过。首次全局 `SWIFT_TREAT_WARNINGS_AS_ERRORS` 与 Package `-suppress-warnings` 的冲突属于工具链证据，非源代码失败。该轮未执行真机、安装/启动或真实服务验证。完整任务记录见 [M8 任务卡](./docs/tasks/2026-08-29-m8-dependency-composition-refinement.md)。

### M9 Runtime State Decomposition（当前代码检查点，2026-08-29）

提交 `8abce82323b58a80f4e6d9c3b79bef92e6150008` 将三类高频可变状态拆为独立、可测试的运行态：`ConversationControllerExecutionState` 管理对话操作、宿主生命周期与连续免按激活 generation；`AudioCaptureRunState` 管理一次采集的 callback token、分块缓冲和停止快照；`VoiceActivatedASRRunState` 管理 VAD/ASR 每轮帧队列、待上传/上传中帧和终态事实。Controller、actor 和音频采集对象仍持有所有 Task、transport 与副作用，拆出的状态对象没有成为第二个并发 owner。

当前复核证据：`SingleGreenGlassesKit` **184/184**、`VoiceChatCore` **109/109**；七 Package 架构边界、Package inventory、repository hygiene、secret scan 与 `git diff --check` 通过；八个公开模块在 macOS arm64 与 iOS Simulator arm64 的 **16** 份 API baseline 通过。该复核没有执行 App-hosted XCTest、App Simulator build、签名构建、真机安装/启动或真实 ASR/LLM/Search 调用，不能替代历史 M8 或设备证据。完整范围见 [M9 任务记录](./docs/tasks/2026-08-29-runtime-state-decomposition.md)。

M1 的首次完整 QA 为五个 Package 150 项 + App-hosted 13 项，共 **163/0**；两项 P2 修复后的受影响复测为 SingleGreenGlassesKit 46 项 + App-hosted 13 项，共 **59/0**。两次均通过通用 Simulator build。详细验收清单和残余人工检查见[架构与升级报告](./docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)及[M1 任务卡](./docs/tasks/2026-08-28-long-term-roadmap.md)。

### M1 refactor PR-02/PR-03（本地实现，2026-08-30）

PR-02 已落地四个 XCConfig 变体和两个产品 Scheme；PR-03 已在本地落地
`codex/internal-debug` 的三 SHA 零差异校验器、PR 目标分支拒绝规则，以及
User/Internal Debug/Release 的 CI 矩阵。Debug 测试后的产物扫描使用单独的
App-only 构建，因为 XCTest 宿主会嵌入 XCTest 支持文件。具体命令、路径、
测试数量和远端限制见 [PR-03 evidence](./docs/refactor/PR03_EVIDENCE.md)；
这不是远端 CI、真机或真实服务验证。

当前上传采用分层 CI：PR 按变更影响选择昂贵门禁，`main` 推送保持全量，内部晋级复用精确
`main` SHA 的 `Required CI` 并只做轻量指针复核。完整流程见 [CI workflow](./docs/CI_WORKFLOW.md)；
该新行为须以下一次上传后的 hosted 结果验证，不能用本地配置代替。

M2 的默认 Profile 为 `simulator.default.v2`：可见区域 8:3、宽度 `0.90`、中心对齐；初始垂直偏移为 `-0.035`，当前宿主视觉调整为 `-0.20`。中立 Profile 位于眼镜核心包，SwiftUI/CoreGraphics 转换器和内存中的宿主选择器留在 `SingleGreenDemo`；非生产标定 Fixture 不代表真实眼镜标定结果。

M3 已将 Experience 元数据和动作目录化。宿主控制面板只消费 Runtime 的 descriptor、active actions 和统一事件入口，不再按 `ExperienceKind` 写分支；能力是声明式元数据，不自动承担权限 gating。当前五个稳定 raw ID 和顺序为 `conversation`、`systemStatus`、`navigation`、`notification`、`caption`。AI 对话声明 network、microphone、backgroundUpdates；其余四个内建本地体验当前无外部能力声明。M3 的事件来源与旧异步更新隔离规则见[架构报告](./docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)。

## AI 对话本机配置

AI 对话采用 provider-neutral Ports & Adapters：`SingleGreenGlassesKit` 只负责编排，宿主 resolver/adapters 准备已配置的 PTT/VAD session 和 Agent。API keys、provider model/resource 配置、credential lease、validation copy 与 raw `web_search` mapping 仅在 `SingleGreenDemo`；核心只消费 opaque Agent context identity 与 semantic external-information activity，并在取消或新一代操作时丢弃 stale preparation。`VoiceChatDomain.ConversationState` 管理消息与请求生命周期，`VoiceChatCore` 负责录音/ASR，`LLMKit` 管理 Agent、SSE 和工具循环。旧的 `SpeechEngineToB`、CocoaPods 和项目内 Ark 客户端路径已移除。先准备：

- 语音技术应用生成的 API Key（WebSocket 请求头使用的 `X-Api-Key` 值）。
- 豆包流式语音识别模型 2.0 小时版资源；Resource ID 为 `volc.seedasr.sauc.duration`。
- DeepSeek API Key；默认模型为 `deepseek-v4-flash`。
- 博查搜索 API Key；仅在开启“模型自主联网搜索”时必填。

运行 App 后点击首页右上角齿轮，在“AI 对话设置”中填写：

| 字段 | 用途 |
| --- | --- |
| `speechAPIKey` | 语音技术应用的 API Key；作为 `X-Api-Key` 发送 |
| `asrResourceID` | 2.0 小时版固定填 `volc.seedasr.sauc.duration` |
| `llmAPIKey` | DeepSeek API Key |
| `llmModel` | OpenAI 兼容 Chat Completions 模型，默认 `deepseek-v4-flash` |
| `enableSearch` | 是否允许 Agent 自主调用联网搜索 |
| `bochaAPIKey` | 博查搜索 API Key，联网搜索开启时必填 |

截图中出现过的凭证应先在控制台轮换，再把新值填入设置页。不要填写 Secret Key，本次 ASR 直连不使用它。

Debug/internal demo 构建可将 ASR、DeepSeek 与博查 API Key 存在系统 Keychain；资源 ID、语言、热词、免按模式、模型 ID 和搜索开关存在本机偏好。旧 `Volcengine.plist` 配置路径已经删除，凭证不得写入工程文件。Release 构建不读取这些 demo Keychain 字段，只接受短期租约 provider；当前生产 transport 是 fail-closed stub，必须在上线前由经过安全评审的应用服务端签发流程替换。

完整链路使用 `idle → connecting → listening → recognizing → thinking → searching（按需）→ streaming → completed / failed` 状态机。手动 PTT 保持原有录音路径；免按模式由本地 VAD 在确认起音后才允许创建 ASR 上传，尾部静音 800ms 或最长 20s 时结束；未检测到起音时 15s 自动结束。LLM 的 SSE 正文增量会立即进入 pending 回复，再由独立字素缓冲以约 150ms 一字（6–7 字/秒）的节奏显示；积压时仍保持稳定逐字输出，Reduce Motion 开启时直接刷新累计前缀。每个回复都有独立 UUID 和 generation，旧任务不能覆盖新回答；重置会取消网络与打字任务并清空多轮上下文。

AI 回答使用专用 `flowingText` HUD 元素：回答区占 safeRect 高度的 61%，字号固定、左对齐且不缩小；内容溢出后自动跟随尾部。上游正常完成且可见缓冲追平后才进入 `completed`。流中失败会保留已接收的部分正文并标记“回答中断”，但 Agent 上下文事务会回滚，不会把失败片段当作完整助手消息。

### AI 对话架构

AI 对话采用轻量的 Ports & Adapters 结构，不把具体服务或系统 API 直接写进状态控制器：

- `VoiceConversationController` 是用例编排层，处理状态转换、任务取消、ASR → Agent 流程以及网络累计文本/可见打字文本的分离。
- `VoiceConversationController` 保持公开的 `@MainActor` 状态/快照 façade；输入协调、回复流水线、显示调度和生命周期投影由内部组件承担。LLMAgent 上下文使用显式 staged transaction，只有显示追平且领域接受后才 commit。
- `ConversationPorts.swift` 集中定义 `SpeechRecognitionSession` 与 `ConversationAgent` 端口，测试可注入内存 Fake。
- `SingleGreenConversationAdapters` 集中存放 VoiceChatCore/LLMKit 到眼镜语义端口的可复用桥接；App 的 `ConversationLiveAdapters.swift` 只保留 provider transport、凭证刷新、工厂和展示策略，供应商细节不进入 Controller。
- `StreamingTextKit` 独立封装打字节奏、字素缓冲、Unicode 增量对齐和自动尾随策略；通过 `TypewriterPolicy` 动态调节而不修改 Controller。
- `LLMAgent` 依赖 `LLMChatTransport` 协议，新 LLM 供应商只需实现语义传输端口。
- `VoiceConversationDependencies` 统一注入配置、麦克风权限、日期和休眠时钟，VAD 与异常分支无需等待真实时间或访问真实硬件。
- `SingleGreenDemoApp` 是模拟器 Composition Root，只在这里组装生产依赖；控制面板只读取 Runtime 发布的 `ExperienceControlState`，不再直接依赖 AI Controller。
- `scripts/strict_concurrency_gate.sh` 对七个 Package 以 Swift 6 complete concurrency 和 warnings-as-errors 执行门禁；Xcode App/Test Debug 与 Release 也启用 Swift 6 complete/WAE。
- `ConversationHUDMapper` 是无副作用的显示映射器，`HUDFlowingTextView` 只负责固定字号与自动尾随，使对话编排与 HUD 表现可以分别测试和演进。
- `ExperienceSession` 的事件与重置接口采用原生 `async`；`ExperienceRuntime` 统一等待旧场景清理和目标场景初始化，并用 generation 防止较慢的旧切换覆盖较新的选择。
- `ExperienceSnapshot` 为后台变化提供统一更新流；相机叠加层和调试信息只读取 `ExperienceRuntime`，AI 场景不再绕过 Runtime 直接输出 HUD。
- Runtime 对场景切换和普通事件共用 command generation；异步旧事件即使较晚完成，也不能覆盖当前场景。

这套拆分参考了 TCA 的可测试状态/副作用思想、Clean Architecture SwiftUI 的 Interactor/Repository 边界，以及可控依赖和测试时钟的实践，但没有为当前规模额外引入第三方架构框架。

仓库当前包含七个本地 Swift Package：`SingleGreenGlassesKit`、`VoiceChatDomain`、`VoiceChatCore`、`LLMKit`、`StreamingTextKit`、`VoiceActivityDetectionKit` 和 `SingleGreenConversationAdapters`。`VoiceActivityDetectionKit` 是独立的框架无关检测/分段包；`SingleGreenConversationAdapters` 提供 VoiceChatCore/LLMKit 到眼镜核心 ports 的可复用语义桥接。生产 WebRTC detector 仅由 `SingleGreenDemo` composition root 注入，设置页仍对独立 AISettings fail-closed，不会把能量检测器作为回退。Experience catalog 允许宿主注册自定义 Experience，控制面板继续只消费通用 descriptor/action。工程已经自包含，不依赖开发者机器上的 AiiOSStudy 目录布局。来源和升级规则见 `Packages/README.md`。

## 本地构建

直接打开 `SingleGreenDemo.xcodeproj`。Xcode 会解析 App 当前使用的七个本地 Package，不需要 CocoaPods 或额外 workspace。

工程包含一个 App Target、两个显式产品 Scheme 和四个配置：`SingleGreenUser` 使用
`User-Debug`/`User-Release`，`SingleGreenInternal` 使用
`Internal-Debug`/`Internal-Release`。用户版 Bundle ID 为
`com.local.SingleGreenDemo`，内部版为 `com.local.SingleGreenDemo.internal`；内部版
额外启用 `INTERNAL_DIAGNOSTICS` 和 `INTERNAL_DEMO_CREDENTIALS`。`DEBUG` 只表示
编译/调试配置，不代表内部能力。完整矩阵见[构建变体与分支策略](./docs/INTERNAL_DIAGNOSTICS_BRANCH_POLICY.md)。

用户版无签名编译：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenUser \
  -configuration User-Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/SingleGreenDemoBuild \
  CODE_SIGNING_ALLOWED=NO \
  build
```

编译 App 与测试 Target（不执行测试）：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenUser \
  -configuration User-Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/SingleGreenDemoBuildForTesting \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

不依赖相机或真实服务的眼镜核心逻辑可在 Mac 上直接执行：

```bash
swift test \
  --package-path Packages/SingleGreenGlassesKit \
  --scratch-path /private/tmp/SingleGreenGlassesKitTests
```

七个本地模块均为 Swift Package，App 和 App-hosted XCTest 可在 iOS Simulator 编译运行。Package 测试覆盖 Experience Runtime、通用控制状态、领域状态、ASR 协议、LLM/SSE、Agent 事务、工具调用、打字策略、Unicode 字素、自动跟随，以及 VAD 帧/分段/并发重置、ASR 门控和宿主适配边界；带真实凭证的网络闭环、真实麦克风和生产 VAD 检测器仍需真机集成测试。

AI 对话编排测试已随核心代码迁入 `SingleGreenGlassesKitTests`。App-hosted XCTest 专注模拟器宿主的组装、设置、Keychain、预览布局和 Runtime 集成。可使用以下命令复测：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenUser \
  -configuration User-Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /private/tmp/SingleGreenDemoTests \
  -enableCodeCoverage YES \
  test
```

2026-08-27 抽取前的稳定基线为 156 项测试、0 失败，并完成 Simulator build 与 Apple Development 签名的 iphoneos arm64 build。覆盖率数据也属于抽取前采样：App 65.72%，`ExperienceRuntime` 90.65%，`AIConversationExperience` 94.12%，`VoiceConversationController` 91.01%，`ConversationHUDMapper` 100%。本次解耦后的当前测试数和构建证据见架构报告。

真机安装前需要在 Xcode 中设置可用的 Apple Developer Team 和唯一 Bundle Identifier。

## 验证边界

当前代码检查点是 M9 runtime-state decomposition。M9 的新鲜证据仅覆盖 `SingleGreenGlassesKit`、`VoiceChatCore` 与静态架构/API/仓库门禁，见 [M9 任务记录](./docs/tasks/2026-08-29-runtime-state-decomposition.md)。M8 的七 Package、App XCTest 与 Simulator build 结果以及此前 PR5 结果均为历史快照；真机部署/启动与用户观察验收同样不是 M9 的重新验证，也不代表完整脚本化 VAD/服务矩阵。
历史 M7 PR5 验证证据为七 Package **438/438**、App-hosted **55/55**、关键生命周期用例 **340/340**，结果包为 `/private/tmp/SingleGreenDemo-M7-PR5-AppTests-Retry/Logs/Test/Test-SingleGreenDemo-2026.08.28_19-46-03-+0800.xcresult`；该证据仅用于历史兼容标记，不覆盖 M9 当前复核，也不代表本轮重新执行。
历史真机基线曾确认首页可运行且主要控件无截断；这不是 M1 的重新验证结果。不同环境光下的 HUD 可读性、连续交互与前后台恢复仍需继续验证。
iPhone 叠加效果不等同于真实眼镜 OST 光学效果。

启动耗时建议在真机强制结束 App 后连续测量 3 次。调试栏中的“相机 x.xx s”从相机控制器创建计时到 `AVCaptureSession.startRunning()` 返回，可用于版本间比较，但不等同于系统从点击图标到首帧完整呈现的时间。

## 关联文档

- [完整架构、质量与模块化升级报告](./docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)
- [流式文本与 LLMKit 模块化升级指南](./docs/STREAMING_MODULES_UPGRADE_GUIDE.md)
- [Codex Agent 协作与升级工作流](./docs/AGENT_WORKFLOW.md)
- [M5 Production Readiness evidence record](./docs/tasks/2026-08-28-production-readiness.md)
- [M6 VAD Stage 1 package contract](./Packages/VoiceActivityDetectionKit/README.md)
- [M6 Stage 2A VAD/ASR integration record](./docs/tasks/2026-08-28-vad-stage2a.md)
- [WebRTC VAD dependency approval ADR](./docs/tasks/2026-08-28-webrtc-vad-approval-adr.md)
- [M7 PR1 architecture/API/toolchain quality baseline](./docs/tasks/2026-08-28-m7-pr1-quality-baseline.md)
- [Public API baseline procedure](./api-baselines/README.md)
- [M7 PR2 lifecycle correctness](./docs/tasks/2026-08-28-m7-pr2-lifecycle-correctness.md)
- [M7 PR3 public reuse contract](./docs/tasks/2026-08-28-m7-pr3-public-reuse-contract.md)
- [M7 PR4 terminal lifecycle](./docs/tasks/2026-08-28-m7-pr4-terminal-lifecycle.md)
- [M7 PR5 mechanical decomposition](./docs/tasks/2026-08-28-m7-pr5-mechanical-decomposition.md)
- [M8 dependency and composition refinement](./docs/tasks/2026-08-29-m8-dependency-composition-refinement.md)
- [M9 runtime state decomposition](./docs/tasks/2026-08-29-runtime-state-decomposition.md)
- [PR-02 build variants evidence](./docs/refactor/PR02_EVIDENCE.md)
- [PR-03 delivery pointer and CI evidence](./docs/refactor/PR03_EVIDENCE.md)
- [AI 对话单绿 HUD 重设计 PRD](./docs/tasks/2026-08-29-ai-conversation-hud-reasoning-prd.md)
- [发布检查单](./docs/RELEASE_CHECKLIST.md)
- [覆盖率基线](./docs/COVERAGE_BASELINE.md)
- [第三方声明与许可证状态](./NOTICE.md)
