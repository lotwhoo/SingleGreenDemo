# 本地 AI Packages

本目录保存 SingleGreenDemo 与后续眼镜能力构建所需的六个本地 Swift Package，使仓库不再依赖开发者机器上的 sibling 目录。

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
LLMKit            独立
VoiceChatCore     → ../LLMKit（仅 ASRCLI 工具使用）
StreamingTextKit  独立
VoiceActivityDetectionKit 独立（M6 Stage 1/2A；WebRTC 实现只在 App composition root 注入）
SingleGreenGlassesKit → VoiceChatDomain + StreamingTextKit
SingleGreenDemo   → SingleGreenGlassesKit + VoiceChatCore + LLMKit + StreamingTextKit
```

## 升级流程

1. 记录目标 AiiOSStudy commit，并确认三个 Package 工作树没有未提交修改。
2. 只同步 `Package.swift`、`Sources/`、`Tests/` 和确有必要的 `Tools/`。
3. 不复制 `.build`、`.swiftpm`、用户状态、凭证或日志。
4. 对比公开 API、Package 平台版本和 Core → LLMKit 相对路径。
5. 依次运行三个上游 Package、`StreamingTextKit`、`VoiceActivityDetectionKit`、`SingleGreenGlassesKit`、App XCTest 和 iOS 构建。
6. 更新本文件的来源提交，并在提交信息中记录行为变化。涉及 VAD 时，先验证 20ms/16kHz/mono/Int16LE 帧契约、300ms pre-roll、3-of-5 起音、800ms 尾部静音、20s 最长段、15s 无起音超时和所有有界队列，再验证连续 rearm、音频通知 wiring、意外 ASR stream closure、PTT 兼容路径及 factory 缺失时的 fail-closed 行为。

## 分发边界

上游同步基线没有通用 LICENSE；本仓库现已随 vendored WebRTC 文件保留 BSD `LICENSE`、`PATENTS`、`AUTHORS`、SPL 归属和 provenance，详见根目录 `NOTICE.md`。这不表示整个仓库采用 WebRTC 许可证；对外分发仍需选择项目许可证并履行二进制 acknowledgements。WebRTC 集成不允许能量检测回退到生产上传；后审计还覆盖连续免按 rearm、音频通知 wiring、意外 ASR stream closure、工具调用参数完整校验和开放宿主 Experience 注册边界。

Provider-neutral 约束：`SingleGreenGlassesKit` 只接收宿主准备好的 PTT/VAD session、opaque Agent context identity 和 semantic external-information activity；API keys、provider model/resource 配置、credential leasing、validation copy 与 raw `web_search` mapping 必须留在 `SingleGreenDemo` resolver/adapters。取消或新一代操作必须丢弃 stale preparation。Experience ID 使用大小写敏感的 ASCII 语法 `[A-Za-z0-9][A-Za-z0-9._-]*`。
