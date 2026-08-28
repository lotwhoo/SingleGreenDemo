# 长程任务：单绿眼镜平台化演进

## 目标

在保持 `SingleGreenDemo` 手机模拟/调试宿主与 `SingleGreenGlassesKit` 眼镜核心解耦的前提下，按产品设计、架构、实现、测试、评审、文档和发布的完整流程推进平台化演进。

## 里程碑状态

| ID | 任务 | 状态 |
| --- | --- | --- |
| M1 | Canonical AI/Runtime Snapshot Contract Hardening | 已实现并验证 |
| M2 | Display Profile v2 / Hardware Boundary | 已实现并完成自动化验证 |
| M3 | Experience Capability Catalog | 已实现并完成自动化验证 |
| M4 | Controller Decomposition / Strict Concurrency | 已实现并完成自动化验证 |
| M5 | Production Readiness / Release System | 自动化基础已实现，发布人工门禁待完成 |
| M6 | Local VAD / Automatic Endpointing | WebRTC production detector 已集成并通过本地回归；真机功能与真实服务门禁待推进 |

## M1：Canonical AI/Runtime Snapshot Contract Hardening

### 已交付

- `ExperienceSession` 提供 `currentSnapshot(eventDescription:)` 兼容入口和 `updates()` 后台更新流。
- `ExperienceRuntime`、AI Experience 和 `VoiceConversationController` 通过统一 `ExperienceSnapshot` 传递 scene、primary action、event description 和 control state。
- Runtime 的激活、普通事件和后台更新共用 generation 与 Session identity 校验。
- 相同快照不重复传播，快照字段以单次赋值保持原子一致。
- 保留已验收 UX 参数：HUD 8:3、宽度 `0.90`、垂直偏移 `-0.035`、文字节奏 `150ms`。

### 验证证据

- 初始完整 QA：五个 Package 150 项 + App-hosted XCTest 13 项，合计 **163 项，0 失败**。
- 两项 P2 修复后受影响复测：SingleGreenGlassesKit 46 项 + App-hosted XCTest 13 项，合计 **59 项，0 失败**。
- 两次验证均包含通用 iOS Simulator build，结果通过。
- 最终评审未发现 P0–P2 问题。
- `streaming_qa` 专项代理容量连续两次不可用；已由等价的独立确定性测试与构建回归完成 QA 兜底。

### 本里程碑不包含

本里程碑没有重新执行签名 iphoneos build、真机安装、真机启动或真实 ASR/LLM/Search 服务验证。此前真机 AI 对话和签名构建属于历史基线，不能作为 M1 的新证据。

## M2：Display Profile v2 / Hardware Boundary（已实现并完成自动化验证）

- `SingleGreenGlassesKit.DisplayProfile` 已成为不可变、`Sendable` 的设备无关值模型，包含可见区域长宽比、surface width、九宫格对齐、垂直偏移、viewport、不对称 safe area、文字/行缩放和 RGB 颜色。
- 初始化已加入类型化校验，覆盖非有限/非正值、viewport 越界、safe-area 边缘和横纵向塌缩、颜色范围，以及派生 presentation aspect ratio 的 overflow/underflow。
- 宿主保留 SwiftUI/CoreGraphics 投影与颜色/矩形转换器；Profile 选择使用进程内 `DisplayProfileStore`，与 Runtime、Experience 状态和活动 AI stream 隔离。
- 默认 Profile 为 `simulator.default.v2`：8:3、宽度 `0.90`、中心对齐、垂直偏移 `-0.035`。另有 `calibration.fixture.non-production.v1`，仅用于测试，不代表生产/真实光学标定。

### M2 验证证据

- SingleGreenGlassesKit 54/0。
- VoiceChatDomain 14/0。
- VoiceChatCore 25/0。
- LLMKit 59/0。
- StreamingTextKit 7/0。
- App-hosted XCTest 20/0。
- 通用 `arm64 + x86_64` Simulator build 通过。
- 最终 QA/评审无 P0–P2 问题。

### M2 未完成的人工检查

- [ ] 模拟器视觉对照：确认默认 Profile 在目标手机上与设计参考一致。
- [ ] 真眼镜光学标定：确认真实设备的可见区域、safe area、亮度和对齐。
- [ ] 本里程碑未执行设备安装、设备启动或真实 ASR/LLM/Search 服务验证。

## M3：Experience Capability Catalog（已实现并完成自动化验证）

- 每个 Experience 声明网络、麦克风、相机、后台更新等能力。
- 将控制面板 action、标题和可用状态改为能力描述驱动。
- 新增 Experience 时不再在宿主维护大段类型 switch。
- 验收：新增体验只需注册自身能力和实现，Runtime、控制面板与测试不依赖具体 Controller 类型。

### 已交付

- 每个 Session 拥有不可变 `ExperienceDescriptor`；`ExperienceCatalog` 对 metadata、动作 ID、primary action 和重复 kind 执行类型化校验。
- 固定五个 raw ID 和顺序：`conversation`、`systemStatus`、`navigation`、`notification`、`caption`。
- 真实能力：AI 对话为 network、microphone、backgroundUpdates；其余四个本地体验能力集合为空。能力是声明式 metadata，不自动执行权限 gating。
- Runtime 提供 `availableDescriptors`、`selectedDescriptor`、`activeActions` 和 `performAction`；宿主按 descriptor/action 渲染，不再按 `ExperienceKind` 写 UI switch。provider detail 由宿主注入。
- 通知 primary action 稳定为 `显示提醒`；`triggerAlert` 显示提醒，`tap`/`swipeDown` 关闭提醒。
- 次级动作网格按数量自适应，测试 fixture/example 提供新增目录项的复用清单。

### 更新来源与竞态保护

- canonical `ExperienceSnapshot` 保持不变，异步传播使用 `ExperienceUpdate` wrapper。
- provenance 区分 opaque command token 与 spontaneous；命令上下文由 `TaskLocal` 捕获，外部回调使用 `ExperienceUpdateSource.current`。
- Runtime 按 Session identity + token 过滤旧更新；action/reset/activation 使用 `expectedKind`，activation 中点再次校验。
- AI 输入使用 `inputOperationGeneration`，取消后迟到的 ASR start 不得重新激活旧输入操作。

### 验证证据

- SingleGreenGlassesKit 86/0；App-hosted XCTest 23/0。
- 紧邻本次 QA 的依赖回归：VoiceChatDomain 14/0、VoiceChatCore 25/0、LLMKit 59/0、StreamingTextKit 7/0。
- 共 214 项相关测试、0 失败；依赖套件属于新鲜回归，但未在 M3 直接范围重复计数。
- 通用 `arm64 + x86_64` Simulator build 通过。
- 最终 QA/评审无 P0–P2 问题。
- App-hosted xcresult：`/private/tmp/SingleGreenDemo-M3FinalReview/Logs/Test/Test-SingleGreenDemo-2026.08.28_02-49-02-+0800.xcresult`。

本里程碑未执行物理设备安装/启动、真实 ASR/LLM/Search 服务或手工视觉验证。

## M4：Controller Decomposition / Strict Concurrency（已实现并完成自动化验证）

- `VoiceConversationController` 保留公开 `@MainActor` sole state/snapshot façade；内部拆分 InputCoordinator、ReplyPipeline、DisplayScheduler 和 LifecycleProjection。初次抽取由 590 行降至 373 行，当前 Controller 为 403 行（后续生命周期与兼容 façade 代码已计入）。
- LLMAgent 使用 staged transaction candidate 与显式 commit/abort；仅在显示追平且领域接受后提交，提交失败或下游失效时 abort。
- 输入 generation、迟到 ASR start 清理、公开 shutdown/deallocation、Runtime observation shutdown、ASR event-cycle/lifecycle serialization 已完成。
- PCM snapshot 保留精确 ASBD/channel layout/channel count/interleaving；诊断已清洗；宿主 speech adapter 为 actor；ObservationBox 已移除。
- 六个 Package、App 和测试 Target 使用 Swift 6 complete/WAE；统一门禁为 `scripts/strict_concurrency_gate.sh`。当前记录在案的 `@unchecked Sendable` 框架边界为 `ASRSession`、`LegacyAudioCaptureCallbacks`、`AudioCaptureRunState`、`PCMFrameSourceRelay` 和 `CameraSessionPipeline`；每一处均有同步边界、理由和测试覆盖。

### M4 验证证据

- StreamingTextKit 7/0、VoiceChatDomain 14/0、SingleGreenGlassesKit 107/0、LLMKit 62/0、VoiceChatCore 35/0、App-hosted XCTest 23/0。
- 合计 **248 项测试，0 失败**。
- Release generic `arm64 + x86_64` Simulator build 通过。
- 最终 QA/评审无 P0–P2 问题。
- xcresult：`/private/tmp/SingleGreenDemo-M4-CommitAck-QA/Logs/Test/Test-SingleGreenDemo-2026.08.28_04-05-35-+0800.xcresult`。

本里程碑未执行物理设备安装/启动、真实 ASR/LLM/Search 服务或设备视觉/无障碍验证。

### M4 残余人工检查

- [ ] 物理麦克风路由、Bluetooth、系统音频中断和后台恢复。
- [ ] 使用真实凭证执行 ASR → LLM → Search。
- [ ] 真机视觉、动态字体、VoiceOver 和真实眼镜光学验证。

## M5：Production Readiness / Release System（自动化基础已实现）

- 已建立 CI 定义、严格并发门禁、App Simulator 测试、Release 通用构建、覆盖率门禁及仓库卫生扫描；GitHub runner 尚未实际执行。
- 最新本地严格 Package QA 为 254/0（StreamingTextKit 7、VoiceChatDomain 15、SingleGreenGlassesKit 125、LLMKit 63、VoiceChatCore 44），App-hosted XCTest 为 35/0；Release generic Simulator 已验证 `arm64 + x86_64`。
- 最新五个 Package 干净 canonical 生产源码覆盖率依次为 75/88（85.23%）、106/107（99.07%）、2362/2532（93.29%）、879/976（90.06%）、878/1277（68.75%）；报告保留在 `/private/tmp/SingleGreenDemo-M5-OwnerFinal-Coverage`。覆盖率不代表真实服务、物理设备、无障碍或光学验证。
- 已加入弱网/401、后台取消、音频系统事件 seam、显示尺寸与 Reduce Motion 的确定性测试；真实设备、蓝牙音频和人工无障碍矩阵待执行。
- 已加入隐私安全的类型化遥测、粗粒度错误码和单调阶段耗时，不记录原始转写、回答、凭证或供应商 payload。
- Debug/internal demo 保留明确标记的 Keychain 方案；Release 使用服务端短期凭证 provider contract 与 fail-closed transport stub，不包含后端实现。
- 已建立 release evidence schema/生成/校验脚本、发布检查单、设备/服务矩阵、回滚流程和 NOTICE/license 状态。
- 详细完成项和待验证项见 [M5 Production Readiness evidence record](./2026-08-28-production-readiness.md)。在真机、真实服务、GitHub runner、签名与回滚证据完成前，不视为生产发布批准。

## M6：Local VAD / Automatic Endpointing（Stage 2A 已实现，生产 detector 待接入）

- 新增独立 Swift 6 `VoiceActivityDetectionKit`，生产库无第三方依赖，不导入录音、网络、UI 或供应商框架。
- 固定 `VADPCMFrame` 为 16 kHz、mono、Int16 little-endian、20 ms、320 samples / 640 bytes，并用严格递增 sequence 隔离重复与回退帧。
- `VoiceActivityDetecting` 为 actor-bound 检测协议；`VADSegmenter` 为确定性值类型，负责有界 pre-roll、N-of-M 起音、内部/尾部静音转发、恢复说话、静音/最长时长单终点和 reset。
- `VoiceActivityDetectionPipeline` 对完整 detect → consume 操作执行 FIFO 串行化；reset 通过 generation 立即丢弃挂起的旧检测并在 detector reset 完成前阻止新一代消费，取消后的迟到检测也不能修改分段状态。
- 简单能量检测器只存在于不可作为库产品选择的 benchmark/test-support target；benchmark 只报告帧数、分段数、终点数和耗时，不记录 PCM 或内容。
- Stage 2A 已将 `VoiceChatCore` 音频帧源、VAD 门控 ASR 会话、眼镜核心 port 和 App adapter 串起来；production detector factory 仍为空。设置页因此 fail closed，不回退到旧 amplitude timer 或 benchmark energy detector；PTT 保持兼容。
- 策略固定为 20ms 帧、300ms pre-roll、3-of-5 起音、800ms 尾部静音、20s 最长段、15s 无起音超时；source/pending-upload 队列均有界，起音确认前不打开 ASR transport。
- `ASRFailure` typed payload 与无 payload `CaptureError.engineFailed` 是有意的本地 Package source migrations，调用方必须使用结构化 code，不传播动态错误描述。
- WebRTC 的具体发行物、来源、许可证、架构、体积和隐私边界已按 ADR 获用户批准并纳入 production detector 阶段。
- WebRTC 接入前的固定 commit、11 upstream C + 1 local compatibility C + 12 upstream headers 闭包、14-vs-11 reconciliation、三架构 compile probe、provenance/hash 清单、性能/语料/真机门禁和未勾选审批框见 [WebRTC VAD 依赖审批 ADR](./2026-08-28-webrtc-vad-approval-adr.md)。该 ADR 不表示已添加依赖或已验证 VAD 质量。

### M6 Stage 1 当前验证证据

- `VoiceActivityDetectionKit` 严格并发/WAE 测试 23/0，其中 gated detector 确定性覆盖 reset 穿越挂起检测、并发 process FIFO，以及取消后的迟到检测丢弃。
- Stage 1 的六包严格门禁 277/0 和覆盖率报告 `/private/tmp/SingleGreenDemo-M6-P1-Coverage` 保留为历史证据。
- Stage 2A 初始快照的六包严格门禁为 **322/322**，App-hosted XCTest **45/45**，xcresult 为 `/private/tmp/SingleGreenDemo-M6-Stage2A-FinalP2-0901.xcresult`；这些是后审计前的历史证据。
- 初始 Stage 2A 覆盖率为 StreamingTextKit 85.23%、VoiceChatDomain 99.07%、VoiceActivityDetectionKit 95.47%、SingleGreenGlassesKit 92.87%、LLMKit 90.06%、VoiceChatCore 73.07%；当前覆盖率见后审计记录和 `COVERAGE_BASELINE.md`。
- Debug 与 Release generic Simulator `arm64 + x86_64` builds 通过；package inventory、privacy/dependency、coverage scope、secret scan、仓库卫生和 `git diff --check` 门禁通过。
- 包清单、VAD 隐私/依赖边界、覆盖率 scope、仓库卫生、隐私日志、secret scan 和 diff whitespace 门禁通过。
- 上一轮 provider-neutral 回归的六包严格门禁 **349/349**（7、16、23、148、70、85）与 App-hosted **48/48**（`/private/tmp/SingleGreenDemo-ProviderNeutral-OwnerApp.xcresult`）现保留为历史快照。其 provider-neutral 边界仍是：API keys、provider model/resource 配置、credential leasing、validation copy 和 raw `web_search` mapping 均留在 App resolver/adapters；核心只消费准备好的 PTT/VAD sessions、opaque Agent context identity 和 semantic external-information activity，并丢弃 stale preparation。Experience ID 遵循 `[A-Za-z0-9][A-Za-z0-9._-]*`。
- （历史 FinalQA2 快照）六包严格门禁 **351/351**、App-hosted **58/58**；具体 detector 尚未实现。当前集成证据见文末 superseding status。
- 当前 throwing-VAD 工作树已完成签名 Debug `iphoneos arm64` build、codesign 和安装，但启动因设备锁定被拒绝；xcresult 为 `/private/tmp/SingleGreenDemo-ThrowingVAD-DeviceBuild.xcresult`，没有当前 PID/运行时证据。此前 Final-P2 PID 稳定的部署证据早于本次 App contract 变更，仅作历史记录。生产 detector factory 仍为空、无 WebRTC；Release backend、GitHub CI、真实服务、许可证和回滚仍待完成。

## 通用流程与门禁

1. 产品 agent 输出目标、用户场景、非目标和验收标准。
2. 架构审查确认依赖方向、公共接口、并发和迁移风险。
3. 实现 agent 进行最小范围代码变更并添加确定性测试。
4. QA 执行受影响测试、全量回归和构建验证；真实设备/服务单独记录。
5. Reviewer 检查 P0–P2、安全性、竞态、兼容性和文档一致性。
6. 文档记录精确测试数、构建目标、手工验证和残余风险。
7. 只有获得明确授权后，才执行签名构建、安装、启动、提交、推送或发布。

## 当前残余人工检查

- [ ] 真机确认相机权限、HUD 位置、8:3 显示区和文字速度。
- [ ] 使用有效凭证验证 ASR → LLM → Search 真实链路。
- [ ] 验证弱网、断网、后台恢复、音频中断、Reduce Motion、VoiceOver 和不同屏幕尺寸。
- [ ] 在真实眼镜硬件可用后完成光学、输入、功耗和温升验收。

### Superseding integrated VAD status (2026-08-28)

The approved minimal WebRTC detector is integrated only at the `SingleGreenDemo` composition root; production factory is non-nil there and inert until arm. Current evidence is six Package **377/377** (7,16,43,150,70,91), App **62/62** at `/private/tmp/SingleGreenDemo-QA-PostWrapper-AppTest.xcresult`, focused ASR/controller **24/24** and **77/77**, VAD ASan/UBSan/TSan **43/43** each, with coverage at `/private/tmp/SingleGreenDemo-QA-PostWrapper-Coverage`. After unlock, mic-fix launch succeeded at 13:29 with PID 5053 stable; the user reported no apparent issues in physical-device testing. This is user-observed acceptance, not a complete scripted VAD/service matrix.

## M7：纯代码质量（PR1–PR5 本地完成，M7 整体继续）

- PR1 建立架构边界、工具链 pin、14 个公开 API snapshots 与 CI 质量门禁；PR1 的 377/377 和 62/62 记录属于历史快照。
- PR2 为 `VoiceActivatedASRSession` 增加单一可注入单调时钟 frame-liveness watchdog，并固定无帧超时、finish、tail drain、actor/generation/epoch 和 one-terminal 契约。
- 当前 PR2 严格 Package 证据为 **390/390**，App 为 **62/62**；完整记录见 [M7 PR2 任务卡](./2026-08-28-m7-pr2-lifecycle-correctness.md)。
- GitHub CI、PR2 真机/真实服务/人工无障碍与光学验证仍未完成。

### M7 PR3 public reuse contract（本地完成，2026-08-28）

- 新增 `SingleGreenConversationAdapters`，公开四个 provider-neutral conversation adapter/policy 类型；核心 ports、provider 配置与宿主策略保持解耦。
- 七 Package 严格并发/WAE **414/414**，App **55/55**；新包 **24/24**，关键生命周期重复 **100/100**。
- 适配器包覆盖率 **347/354（98.02%）**；Debug 与严格 Release Simulator builds、架构/公开 API/仓库卫生门禁通过。
- 公开 API 基线为八个模块、16 个 macOS arm64/iOS Simulator arm64 snapshots。PR3 未执行 GitHub CI、真机、真实服务、无障碍或光学验收。
- 详细范围、兼容契约与升级清单见 [M7 PR3 任务卡](./2026-08-28-m7-pr3-public-reuse-contract.md)。

### M7 PR4 terminal lifecycle（历史本地完成，已由 PR5 supersede，2026-08-28）

- `VoiceConversationController.shutdown()` 现为幂等、可并发 join 的终态操作；生命周期、输入、reset 和自动 rearm 任务均被保留并等待清理，shutdown 后拒绝迟到事件与新操作。
- `ExperienceRuntime.init(validating:)` 作为兼容性加法 API 纳入八模块/16 snapshots 基线。
- PR3+PR4 历史合并证据：七 Package **438/438**（7、16、43、174、24、70、104）、App **55/55**；适配器重复 480、终态生命周期重复 380；`SingleGreenGlassesKit` 94.08%、适配器 98.02%；Debug/严格 universal Release Simulator 通过。该证据已由当前 PR5 隔离复测 supersede。
- 未声明真机、实时服务、GitHub CI、无障碍、光学或回滚证据。详见 [M7 PR4 任务卡](./2026-08-28-m7-pr4-terminal-lifecycle.md)。

### M7 PR5 mechanical decomposition（本地完成，2026-08-28）

- 仅四个文件发生 PR5 机械拆分：内部 `ConversationTelemetryTracker` 承接同步 telemetry bookkeeping，控制器继续拥有任务、取消、generation 和生命周期；95 个 Controller 测试方法的名称、方法体和断言保持不变，支持 helpers/fixtures 移入独立支持文件。
- 隔离复测：`SingleGreenGlassesKit` **174/174**，关键用例 **17×20=340/340**，App **55/55**；SGK 覆盖率 **93.91%**，适配器 **98.02%**；八模块两架构 **16** 个 API snapshots byte-identical；架构负例 **11**。
- Debug 与 universal Release Simulator（arm64+x86_64）构建及独立评审 GO 均已通过。并发 simulator 仅产生 timing warning；已完成隔离的 55/55 重跑。
- PR5 未执行真机、真实服务、GitHub CI、commit 或 push。详见 [M7 PR5 任务卡](./2026-08-28-m7-pr5-mechanical-decomposition.md)。
