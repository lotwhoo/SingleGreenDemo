# 本地 AI Packages

本目录保存 SingleGreenDemo 与后续眼镜能力构建所需的七个本地 Swift Package，使仓库不再依赖开发者机器上的 sibling 目录。

## 来源基线

- 上游仓库：`git@github.com:lotwhoo/AiiOSstudy.git`
- 上游提交：`f05467c9243e9ac498e1e2874a08445d3380b034`
- 提交日期：2026-08-27
- 提交标题：`test: harden conversation and protocol boundaries`
- 纳入日期：2026-08-27

纳入时三个上游 Package 路径均没有未提交源码变更。`.build`、`.swiftpm`、`.DS_Store` 和 Xcode 用户状态未复制。

`StreamingTextKit`、`SingleGreenGlassesKit` 和 `VoiceActivityDetectionKit` 是本项目内建立的模块，不属于上述 AiiOSStudy 同步基线。前者封装打字策略、字素缓冲、Unicode 对齐和自动尾随判定；`SingleGreenGlassesKit` 封装可独立迭代的眼镜领域模型、Runtime、Experience 和 AI 对话编排；`VoiceActivityDetectionKit` 保持无框架、无第三方依赖，拥有本地 VAD 帧、检测协议和端点分段状态机的稳定边界。Stage 2A 的录音/上传编排位于 `VoiceChatCore`，眼镜核心与 App 只依赖 provider-neutral ports。

生产 WebRTC detector 已获用户批准并集成，仅由 `SingleGreenDemo` composition root 链接；`VoiceActivityDetectionKit` 保持 project-maintained 公共 port。11 upstream C + 1 project compatibility C + 12 upstream headers、隐藏 wrapper、五符号 facade、许可清单和三架构门禁见 [WebRTC VAD ADR](../docs/tasks/2026-08-28-webrtc-vad-approval-adr.md)。

## 依赖关系

```text
VoiceChatDomain   独立
LLMKit Package    LLMCore ← AgentCore / OpenAICompatibleTransport / BochaSearchAdapter；LLMKit 兼容导出四者
VoiceChatCore     → ../LLMKit 的四个窄产品（仅 ASRCLI 工具使用）
StreamingTextKit  独立
VoiceActivityDetectionKit 独立（M6 Stage 1/2A；WebRTC 实现只在 App composition root 注入）
SingleGreenGlassesKit → VoiceChatDomain + StreamingTextKit
SingleGreenConversationAdapters → SingleGreenGlassesKit + VoiceChatCore + AgentCore + LLMCore
SingleGreenDemo   → SingleGreenConversationAdapters + SingleGreenGlassesKit + VoiceChatCore + AgentCore + LLMCore + OpenAICompatibleTransport + BochaSearchAdapter + StreamingTextKit
```

`SingleGreenConversationAdapters` 的复用接口包括 `VoiceChatSpeechRecognitionAdapter`、`VoiceChatSupervisedSpeechRecognitionAdapter`、`VoiceChatVoiceActivatedSpeechRecognitionAdapter`、`LLMKitConversationAgentAdapter` 和 `LLMKitConversationAgentAdapterPolicy`。它们只桥接核心 ports 与已配置的 VoiceChat/LLM 实现；凭证、租约、恢复预算与降级选择、模型/资源配置、WebRTC factory、raw tool name 和展示文案仍由 App composition root 提供。

M12 恢复契约位于 `VoiceChatCore` 内部 `ASRSupervision` Target：PTT 与 Voice Activated 均通过 generation 拒绝旧事件，并在旧 Session cancel 完成后才允许新 Session。Voice Activated 一旦接受本地 VAD 起音就不再换 Session，避免丢失当前话语 pre-roll。多 Feature 的麦克风租约位于 App，不属于 Package 契约；当前采用非抢占模式，生产自动恢复预算保持 0，等待真机故障矩阵后再定参数。

M13-PR1 将 `LLMKit` Package 内部拆为两个可独立引用的 Core Target：`LLMCore` 保有 Message、Tool、StreamingEvent、Transport 和类型化错误；`AgentCore` 只依赖 `LLMCore`，保有上下文事务、Tool Round、commit/abort 和终态规则。M13-PR2 再将 OpenAI-compatible HTTP/SSE 与协议线模型移入 `OpenAICompatibleTransport`，将 `BochaSearchClient` 与响应模型移入 `BochaSearchAdapter`。App Composition Root、ASRCLI 和语义桥接改用窄产品，`LLMKit` 只保留兼容导出。

## 升级流程

1. 记录目标 AiiOSStudy commit，并确认三个 Package 工作树没有未提交修改。
2. 只同步 `Package.swift`、`Sources/`、`Tests/` 和确有必要的 `Tools/`。
3. 不复制 `.build`、`.swiftpm`、用户状态、凭证或日志。
4. 对比公开 API、Package 平台版本和 Core → LLMKit 相对路径。
5. 依次运行七个本地 Package、App XCTest 和 iOS 构建；当前 PR3 本地证据为 Package **414/414**、App **55/55**，适配器包 **24/24**。
6. PR3+PR4 合并复核应达到七个 Package **438/438**、App **55/55**；适配器生命周期重复 480 次、终态生命周期重复 380 次。
7. 更新本文件的来源提交，并在提交信息中记录行为变化。涉及 VAD 时，先验证 20ms/16kHz/mono/Int16LE 帧契约、300ms pre-roll、3-of-5 起音、800ms 尾部静音、20s 最长段、15s 无起音超时和所有有界队列，再验证连续 rearm、音频通知 wiring、意外 ASR stream closure、PTT 兼容路径及 factory 缺失时的 fail-closed 行为。

## 分发边界

上游同步基线没有通用 LICENSE；本仓库现已随 vendored WebRTC 文件保留 BSD `LICENSE`、`PATENTS`、`AUTHORS`、SPL 归属和 provenance，详见根目录 `NOTICE.md`。这不表示整个仓库采用 WebRTC 许可证；对外分发仍需选择项目许可证并履行二进制 acknowledgements。WebRTC 集成不允许能量检测回退到生产上传；后审计还覆盖连续免按 rearm、音频通知 wiring、意外 ASR stream closure、工具调用参数完整校验和开放宿主 Experience 注册边界。

Provider-neutral 约束：`SingleGreenGlassesKit` 只接收宿主准备好的 PTT/VAD session、opaque Agent context identity 和 semantic external-information activity；API keys、provider model/resource 配置、credential leasing、validation copy 与 raw `web_search` mapping 必须留在 `SingleGreenDemo` resolver/adapters。取消或新一代操作必须丢弃 stale preparation。Experience ID 使用大小写敏感的 ASCII 语法 `[A-Za-z0-9][A-Za-z0-9._-]*`。

## Public API baseline procedure

The reviewed public API contract is generated with `swift-api-digester` for the ten library modules listed in `config/architecture-boundaries.json`, on macOS arm64 and iOS Simulator arm64. Exact snapshots are stored under `api-baselines/xcode-26.6-swift-6.3.3/`; additions and removals are both review items.

Run `scripts/check_public_api_baselines.sh` during normal validation. To intentionally accept a reviewed API change, run `scripts/update_public_api_baselines.sh --accept-current-api`, inspect the generated JSON diff and compatibility impact, then run the checker and relevant package tests. The update command is never automatic and is rejected in CI. The updater stages and preserves a rollback copy on replacement failure; concurrent invocations remain a known P3 limitation.
