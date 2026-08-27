# 单绿显示实验室

原生 SwiftUI iOS Demo，用 iPhone 后摄画面模拟环境透视，并叠加可扩展的单绿 HUD Experience。

## 当前完成范围

- Xcode 原生 App 与单元测试 Target。
- iOS 26.0 Deployment Target。
- iPhone 17 Pro Max / iOS 26 作为主要验收环境。
- 后摄权限、预览和无权限替代背景。
- 通用 `DemoEvent → Experience → HUDScene → Renderer` 链路。
- `simulator.default.v1` DisplayProfile。
- 基础状态、导航、通知、字幕/提词四个本地 Experience。
- AI 对话 Experience：完整接入 `VoiceChatDomain`、`VoiceChatCore`、`LLMKit` 与可复用 `StreamingTextKit`，形成豆包流式 ASR → DeepSeek Agent → 按需博查联网搜索 → 字素安全显示链路。
- 首页采用全屏相机内容层，状态、调试与控制面板作为悬浮功能层。
- 使用 SwiftUI 原生 Material 与 iOS 26 Liquid Glass：普通内容容器使用标准材质，关键交互按钮使用可交互玻璃效果。
- 原生场景 Menu、悬浮诊断条、三个手势按钮与紧凑的 HUD 显示控制。
- HUD 开关、模拟强度、上滑、点击、下滑和体验重置。
- 相机配置与启停在专用队列执行，首屏先显示、后摄异步预热。
- 调试模式显示本次冷启动的相机 Session 启动耗时。

## AI 对话本机配置

AI 对话采用 AiiOSStudy 已验证的模块边界：App 只负责编排，`VoiceChatDomain.ConversationState` 管理消息与请求生命周期，`VoiceChatCore.ASRSession` 负责录音、SAUC 帧、gzip 和 WebSocket，`LLMKit.LLMAgent` 管理多轮上下文和工具循环，`BochaSearchClient` 执行模型自主发起的 `web_search`。旧的 `SpeechEngineToB`、CocoaPods 和项目内 Ark 客户端路径已移除。先准备：

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

ASR、DeepSeek 与博查 API Key 存在系统 Keychain；资源 ID、语言、热词、免按模式、模型 ID 和搜索开关存在本机偏好。旧 `Volcengine.plist` 配置路径已经删除，凭证不得写入工程文件。客户端 Keychain 仍不是服务端鉴权隔离，外部测试或上线前应改为服务端签发短期凭证。

完整链路使用 `idle → connecting → listening → recognizing → thinking → searching（按需）→ streaming → completed / failed` 状态机。`listening` 阶段显示实时转写和录音电平；免按模式会在静音 1.5 秒后自动结束；识别结束后自动请求 Agent。LLM 的 SSE 正文增量会立即进入 pending 回复，再由独立字素缓冲以不高于 30Hz 的节奏显示；积压时自适应追平，Reduce Motion 开启时直接刷新累计前缀。每个回复都有独立 UUID 和 generation，旧任务不能覆盖新回答；重置会取消网络与打字任务并清空多轮上下文。

AI 回答使用专用 `flowingText` HUD 元素：回答区占 safeRect 高度的 61%，字号固定、左对齐且不缩小；内容溢出后自动跟随尾部。上游正常完成且可见缓冲追平后才进入 `completed`。流中失败会保留已接收的部分正文并标记“回答中断”，但 Agent 上下文事务会回滚，不会把失败片段当作完整助手消息。

### AI 对话架构

AI 对话采用轻量的 Ports & Adapters 结构，不把具体服务或系统 API 直接写进状态控制器：

- `VoiceConversationController` 是用例编排层，处理状态转换、任务取消、ASR → Agent 流程以及网络累计文本/可见打字文本的分离。
- `ConversationPorts.swift` 集中定义 `SpeechRecognitionSession` 与 `ConversationAgent` 端口，测试可注入内存 Fake。
- `ConversationLiveAdapters.swift` 集中存放 `VoiceChatSpeechRecognitionSession` 与 `LLMKitConversationAgent`，供应商 SDK 不进入 Controller。
- `StreamingTextKit` 独立封装打字节奏、字素缓冲、Unicode 增量对齐和自动尾随策略；通过 `TypewriterPolicy` 动态调节而不修改 Controller。
- `LLMAgent` 依赖 `LLMChatTransport` 协议，新 LLM 供应商只需实现语义传输端口。
- `VoiceConversationDependencies` 统一注入配置、麦克风权限、日期和休眠时钟，VAD 与异常分支无需等待真实时间或访问真实硬件。
- `SingleGreenDemoApp` 是 Composition Root，只在这里组装生产依赖，并让控制面板与 Experience 共用同一个 Controller 实例。
- `ConversationHUDMapper` 是无副作用的显示映射器，`HUDFlowingTextView` 只负责固定字号与自动尾随，使对话编排与 HUD 表现可以分别测试和演进。
- `ExperienceSession` 的事件与重置接口采用原生 `async`；`ExperienceRuntime` 统一等待旧场景清理和目标场景初始化，并用 generation 防止较慢的旧切换覆盖较新的选择。
- `ExperienceSnapshot` 为后台变化提供统一更新流；相机叠加层和调试信息只读取 `ExperienceRuntime`，AI 场景不再绕过 Runtime 直接输出 HUD。
- Runtime 对场景切换和普通事件共用 command generation；异步旧事件即使较晚完成，也不能覆盖当前场景。

这套拆分参考了 TCA 的可测试状态/副作用思想、Clean Architecture SwiftUI 的 Interactor/Repository 边界，以及可控依赖和测试时钟的实践，但没有为当前规模额外引入第三方架构框架。

当前 Xcode 工程引用仓库内四个本地 Swift Package：`VoiceChatDomain`、`VoiceChatCore`、`LLMKit` 和 `StreamingTextKit`。工程已经自包含，不依赖开发者机器上的 AiiOSStudy 目录布局。来源和升级规则见 `Packages/README.md`。

## 本地构建

直接打开 `SingleGreenDemo.xcodeproj`。Xcode 会解析仓库内 `Packages/` 中的四个本地 Package，不需要 CocoaPods 或额外 workspace。

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

不依赖相机或火山真机 SDK 的领域逻辑可在 Mac 上直接执行：

```bash
swift test --scratch-path /private/tmp/SingleGreenCoreTests
```

四个 AI 基础模块均为 Swift Package，App 和 App-hosted XCTest 可在 iOS Simulator 编译运行。Package 测试覆盖领域状态、ASR 协议、LLM/SSE、Agent 事务、工具调用、打字策略、Unicode 字素和自动跟随；带真实凭证的网络闭环仍需真机集成测试。

App-hosted XCTest 另有 AI 对话编排测试，覆盖累计转写、真实 delta 顺序、字素完整性、完成时机、部分失败、迟到事件隔离、专用 HUD 几何、联网搜索状态、任务取消、上下文清理、可控 VAD 时钟和配置快照。可使用以下命令复测并生成覆盖率结果：

```bash
xcodebuild \
  -project SingleGreenDemo.xcodeproj \
  -scheme SingleGreenDemo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /private/tmp/SingleGreenDemoTests \
  -enableCodeCoverage YES \
  test
```

2026-08-27 流式模块化后，已使用 Xcode 26.5 / iOS 26.5 SDK 完成 Simulator XCTest、双架构 Simulator build 和 Apple Development 签名的 iphoneos arm64 build。当前测试合计 156 项、0 失败。覆盖率数据为模块抽取前最近一次采样：App 65.72%，`ExperienceRuntime` 90.65%，`AIConversationExperience` 94.12%，`VoiceConversationController` 91.01%，`ConversationHUDMapper` 100%。本次结构重构不改变真机功能和 UI 行为。

真机安装前需要在 Xcode 中设置可用的 Apple Developer Team 和唯一 Bundle Identifier。

## 验证边界

当前已通过四个本地 Package、平台 Core、iOS Simulator App-hosted XCTest 和签名 iphoneos arm64 构建。iOS 真机上的 ASR → LLM → 搜索完整网络链路依赖有效的 ASR、DeepSeek 和博查凭证。
真机已确认首页可运行且主要控件无截断；不同环境光下的 HUD 可读性、连续交互与前后台恢复仍需继续验证。
iPhone 叠加效果不等同于真实眼镜 OST 光学效果。

启动耗时建议在真机强制结束 App 后连续测量 3 次。调试栏中的“相机 x.xx s”从相机控制器创建计时到 `AVCaptureSession.startRunning()` 返回，可用于版本间比较，但不等同于系统从点击图标到首帧完整呈现的时间。

## 关联文档

- [完整架构、质量与模块化升级报告](./docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)
- [流式文本与 LLMKit 模块化升级指南](./docs/STREAMING_MODULES_UPGRADE_GUIDE.md)
- [Codex Agent 协作与升级工作流](./docs/AGENT_WORKFLOW.md)
