# M4 任务卡：Controller Decomposition / Strict Concurrency

## 目标

在不破坏公开 API 的前提下，降低 AI 对话编排复杂度，明确输入、回复、显示和生命周期边界，并让 Package/App 的 Swift 6 strict concurrency 门禁可重复执行。

## 已完成

- `VoiceConversationController` 保持公开 `@MainActor` sole state/snapshot façade。
- 内部提取 `ConversationInputCoordinator`、`ConversationReplyPipeline`、`ConversationDisplayScheduler` 和 `ConversationLifecycleProjection`；初次抽取从 590 行降至 373 行，当前 Controller 为 403 行。
- LLMAgent staged candidate 通过显式 token `commit`/`abort` 管理上下文；仅在显示追平且领域接受后 commit，commit 失败也 abort。
- 输入 generation、取消后 stale ASR start 清理、公开 shutdown/deallocation、Runtime observation shutdown 和 ASR event-cycle/lifecycle serialization 已完成。
- PCM snapshot 保留 ASBD、channel layout、channel count/interleaving；诊断信息经过清洗。
- 宿主 `VoiceChatSpeechRecognitionSession` 为 actor，`ObservationBox` 已移除。
- 六个 Package、App 和测试 Target 使用 Swift 6 complete concurrency 与 WAE；门禁脚本为 `scripts/strict_concurrency_gate.sh`。
- 当前生产代码中的 `@unchecked Sendable` 仅出现在明确的同步/系统回调边界：`VoiceChatCore.ASRSession`、`LegacyAudioCaptureCallbacks`、`AudioCaptureRunState`、`PCMFrameSourceRelay` 和 `CameraSessionPipeline`。每一处都必须保留边界理由与对应测试；不得将其作为一般并发逃生口。

## 验证证据

- StreamingTextKit 7/0；VoiceChatDomain 14/0；SingleGreenGlassesKit 107/0；LLMKit 62/0；VoiceChatCore 35/0；App-hosted XCTest 23/0。
- 合计 **248/0**。
- Release generic `arm64 + x86_64` Simulator build 通过。
- 最终 QA/评审无 P0–P2。
- xcresult：`/private/tmp/SingleGreenDemo-M4-CommitAck-QA/Logs/Test/Test-SingleGreenDemo-2026.08.28_04-05-35-+0800.xcresult`。

## 未完成验证

- 物理麦克风路由、Bluetooth、音频中断和后台恢复。
- 真实 ASR → LLM → Search 服务。
- 真机视觉、无障碍和真实眼镜光学验证。

本任务没有执行设备安装/启动，也没有使用真实服务凭证。

## 后续本地 Package source migrations

M6 Stage 2A 将 ASR 错误迁移为 typed `ASRFailure` payload，并将 `AudioCapture.CaptureError.engineFailed` 固定为 payload-free error。这两项是有意的本地 Package source migrations：调用方应依赖稳定的错误 code，不应传播动态框架描述、provider payload 或设备信息。
