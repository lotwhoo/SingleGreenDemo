# 单绿显示实验室

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
- HUD 模拟显示区域使用约 8:3 可见长宽比并在预览区中心对齐。
- 相机配置与启停在专用队列执行，首屏先显示、后摄异步预热。
- 调试模式显示本次冷启动的相机 Session 启动耗时。

## 长程开发路线

项目按产品设计、架构、实现、测试、评审、文档和发布的完整流程推进。当前 M1–M7 的自动化基础已按下表推进：

| 里程碑 | 目标 | 状态 |
| --- | --- | --- |
| M1 | Canonical AI/Runtime Snapshot：统一 `ExperienceSnapshot`、`currentSnapshot` 兼容入口、原子化去重传播 | 已实现并验证 |
| M2 | Display Profile v2 / Hardware Boundary：分离中立显示参数与 SwiftUI，并建立真实硬件适配边界 | 已实现并完成自动化验证 |
| M3 | Experience Capability Catalog：声明网络、麦克风、相机、后台更新和可用操作 | 已实现并完成自动化验证 |
| M4 | Controller Decomposition / Strict Concurrency：拆分对话控制器并收紧并发隔离 | 已实现并完成自动化验证 |
| M5 | Production Readiness / Release System：CI、设备回归、短期凭证、观测和发布流程 | 自动化基础已实现，人工门禁待完成 |
| M6 | Local VAD / Automatic Endpointing：本地检测、自动端点和 ASR 门控 | WebRTC production detector 已集成并通过本地回归；真机/真实服务门禁待完成 |
| M7 | 纯代码质量：架构边界、工具链、公开 API 与生命周期正确性 | PR1、PR2 已在本地完成；M7 整体继续推进 |

M7 PR1 的本地证据为六个 Package 严格并发 **377/377**、App XCTest **62/62**、架构边界 10 个负例和 14 个公开 API snapshot 门禁通过；该记录属于历史快照，见 [M7 PR1 任务卡](./docs/tasks/2026-08-28-m7-pr1-quality-baseline.md)。

当前 M7 PR2 已在本地完成 VAD/ASR 生命周期正确性加固：六个 Package 严格并发 **390/390**，其中 `VoiceChatCore` 104 项；App XCTest **62/62**。`VoiceActivatedASRSession` 使用单一可注入单调时钟 watchdog 处理无帧超时，并保留 pre-onset/post-onset finish 与尾部排空契约。完整证据见 [M7 PR2 任务卡](./docs/tasks/2026-08-28-m7-pr2-lifecycle-correctness.md)。GitHub Actions 尚未执行，PR2 未进行真机、真实服务或人工无障碍/光学验收。

M1 的首次完整 QA 为五个 Package 150 项 + App-hosted 13 项，共 **163/0**；两项 P2 修复后的受影响复测为 SingleGreenGlassesKit 46 项 + App-hosted 13 项，共 **59/0**。两次均通过通用 Simulator build。详细验收清单和残余人工检查见[架构与升级报告](./docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)及[M1 任务卡](./docs/tasks/2026-08-28-long-term-roadmap.md)。

M2 的默认 Profile 为 `simulator.default.v2`：可见区域 8:3、宽度 `0.90`、中心对齐、垂直偏移 `-0.035`。中立 Profile 位于眼镜核心包，SwiftUI/CoreGraphics 转换器和内存中的宿主选择器留在 `SingleGreenDemo`；非生产标定 Fixture 不代表真实眼镜标定结果。

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
- `ConversationLiveAdapters.swift` 集中存放 `VoiceChatSpeechRecognitionSession` 与 `LLMKitConversationAgent`，供应商 SDK 不进入 Controller。
- `StreamingTextKit` 独立封装打字节奏、字素缓冲、Unicode 增量对齐和自动尾随策略；通过 `TypewriterPolicy` 动态调节而不修改 Controller。
- `LLMAgent` 依赖 `LLMChatTransport` 协议，新 LLM 供应商只需实现语义传输端口。
- `VoiceConversationDependencies` 统一注入配置、麦克风权限、日期和休眠时钟，VAD 与异常分支无需等待真实时间或访问真实硬件。
- `SingleGreenDemoApp` 是模拟器 Composition Root，只在这里组装生产依赖；控制面板只读取 Runtime 发布的 `ExperienceControlState`，不再直接依赖 AI Controller。
- `scripts/strict_concurrency_gate.sh` 对六个 Package 以 Swift 6 complete concurrency 和 warnings-as-errors 执行门禁；Xcode App/Test Debug 与 Release 也启用 Swift 6 complete/WAE。
- `ConversationHUDMapper` 是无副作用的显示映射器，`HUDFlowingTextView` 只负责固定字号与自动尾随，使对话编排与 HUD 表现可以分别测试和演进。
- `ExperienceSession` 的事件与重置接口采用原生 `async`；`ExperienceRuntime` 统一等待旧场景清理和目标场景初始化，并用 generation 防止较慢的旧切换覆盖较新的选择。
- `ExperienceSnapshot` 为后台变化提供统一更新流；相机叠加层和调试信息只读取 `ExperienceRuntime`，AI 场景不再绕过 Runtime 直接输出 HUD。
- Runtime 对场景切换和普通事件共用 command generation；异步旧事件即使较晚完成，也不能覆盖当前场景。

这套拆分参考了 TCA 的可测试状态/副作用思想、Clean Architecture SwiftUI 的 Interactor/Repository 边界，以及可控依赖和测试时钟的实践，但没有为当前规模额外引入第三方架构框架。

仓库当前包含六个本地 Swift Package：`SingleGreenGlassesKit`、`VoiceChatDomain`、`VoiceChatCore`、`LLMKit`、`StreamingTextKit` 和 `VoiceActivityDetectionKit`。`VoiceActivityDetectionKit` 是独立的框架无关检测/分段包；Stage 2A 已将其端口接入 `VoiceChatCore` 的音频帧和 ASR 门控会话，并通过眼镜核心与 App 适配器暴露能力。生产 WebRTC detector 仅由 `SingleGreenDemo` composition root 注入，设置页仍对独立 AISettings fail-closed，不会把能量检测器作为回退。Experience catalog 允许宿主注册自定义 Experience，控制面板继续只消费通用 descriptor/action。工程已经自包含，不依赖开发者机器上的 AiiOSStudy 目录布局。来源和升级规则见 `Packages/README.md`。

## 本地构建

直接打开 `SingleGreenDemo.xcodeproj`。Xcode 会解析 App 当前使用的六个本地 Package，不需要 CocoaPods 或额外 workspace。

工程使用临时 Bundle Identifier `com.local.SingleGreenDemo`。无签名编译：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenDemo \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/SingleGreenDemoBuild \
  CODE_SIGNING_ALLOWED=NO \
  build
```

编译 App 与测试 Target（不执行测试）：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenDemo \
  -configuration Debug \
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

六个本地模块均为 Swift Package，App 和 App-hosted XCTest 可在 iOS Simulator 编译运行。Package 测试覆盖 Experience Runtime、通用控制状态、领域状态、ASR 协议、LLM/SSE、Agent 事务、工具调用、打字策略、Unicode 字素、自动跟随，以及 VAD 帧/分段/并发重置、ASR 门控和宿主适配边界；带真实凭证的网络闭环、真实麦克风和生产 VAD 检测器仍需真机集成测试。

AI 对话编排测试已随核心代码迁入 `SingleGreenGlassesKitTests`。App-hosted XCTest 专注模拟器宿主的组装、设置、Keychain、预览布局和 Runtime 集成。可使用以下命令复测：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /private/tmp/SingleGreenDemoTests \
  -enableCodeCoverage YES \
  test
```

2026-08-27 抽取前的稳定基线为 156 项测试、0 失败，并完成 Simulator build 与 Apple Development 签名的 iphoneos arm64 build。覆盖率数据也属于抽取前采样：App 65.72%，`ExperienceRuntime` 90.65%，`AIConversationExperience` 94.12%，`VoiceConversationController` 91.01%，`ConversationHUDMapper` 100%。本次解耦后的当前测试数和构建证据见架构报告。

真机安装前需要在 Xcode 中设置可用的 Apple Developer Team 和唯一 Bundle Identifier。

## 验证边界

当前的离线验证边界包括六个本地 Package、iOS Simulator App-hosted XCTest 和 Simulator 构建。最新严格证据为六 Package **377/377**（7、16、43、150、70、91）、App-hosted **62/62**（`/private/tmp/SingleGreenDemo-QA-PostWrapper-AppTest.xcresult`），ASR/controller focused 分别 **24/24**、**77/77**，VAD ASan/UBSan/TSan 各 **43/43**；覆盖率路径为 `/private/tmp/SingleGreenDemo-QA-PostWrapper-Coverage`。Debug/Release universal Simulator、unsigned Release iphoneos 和静态门禁通过。解锁后麦克风修复工作树于 2026-08-28 13:29 启动成功，PID 5053 稳定（`/private/tmp/SingleGreenDemo-MicFix-DeviceBuild.xcresult`）；用户随后反馈真机测试“没什么问题”。这是命令级部署/启动证据加用户观察验收，仍不是完整脚本化 VAD/服务矩阵。修复为先激活 AVAudioSession 再读取 graph format、过滤 categoryChange 并保留真实启动/运行时 observer，启动错误映射为 `audioUnavailable`；此前锁屏阻断仅为瞬时环境记录。
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
- [发布检查单](./docs/RELEASE_CHECKLIST.md)
- [覆盖率基线](./docs/COVERAGE_BASELINE.md)
- [第三方声明与许可证状态](./NOTICE.md)
