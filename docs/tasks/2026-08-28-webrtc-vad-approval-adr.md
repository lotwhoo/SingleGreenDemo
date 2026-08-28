# ADR：生产 WebRTC VAD 依赖审批与接入前检查点

**状态：已获用户批准并完成实现**
**日期：2026-08-28**
**范围：M6 Local VAD / Automatic Endpointing 的 production detector**

## 决策摘要

当前 `VoiceActivityDetectionKit`、`VoiceChatCore` 和 `SingleGreenGlassesKit` 提供
provider-neutral 的本地 VAD 端口、分段器、pre-roll、自动端点和 ASR 门控编排；获批准的
最小 WebRTC detector 已集成，且只在 `SingleGreenDemo` composition root 链接。生产 root
factory 非空但在显式 arm 前保持 inert，mode 2 使用 `.aggressive`；独立 AISettings
仍 fail-closed，绝不回退到 `VADBenchmarkSupport` 能量检测器。

本 ADR 记录依赖审批、源码闭包和已完成的实现。它不证明真实 VAD 质量、麦克风、ASR、
真实服务或真机功能；这些仍是独立的人工门禁。

> **审批：** [x] 用户已明确批准按本文方案引入固定版本 WebRTC VAD 的最小源码闭包，并进入实现、测试和真机功能验收阶段。

## 已验证的上游与工具链事实

可复核证据目录：`/private/tmp/webrtc-vad-feasibility.XSG7a1/`，报告为
`PROBE_REPORT.md`。该目录是一次性的、仓库外的 compile/API probe，不是项目依赖。

| 项目 | 已核对值 |
| --- | --- |
| 官方 remote | `https://webrtc.googlesource.com/src` |
| detached commit | `1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1` |
| author date | `2026-08-26T21:10:36-07:00` |
| commit date | `2026-08-26T23:08:09-07:00` |
| subject | `Update WebRTC code version (2026-08-27T04:10:02).` |
| compiler | Apple clang 21.0.0 (`clang-2100.1.1.101`) |
| SDKs | iPhoneOS 26.5、iPhoneSimulator 26.5 |
| language/warnings | C11；release `-Wall -Wextra -Wpedantic`，debug 加 `-Werror` |
| target triples | `arm64-apple-ios17.0`、`arm64-apple-ios17.0-simulator`、`x86_64-apple-ios17.0-simulator` |

六个 compile-and-link 变体（上述三架构的 release-style 与 debug-style）均以零警告、
零错误完成，且生成 Mach-O harness。这只证明源码闭包在当前 Apple-Clang/SDK 组合下
可编译链接，不代表采用、质量、功耗或设备行为。

### Apple-Clang 不变量

生产实现必须保留当前 probe 的编译不变量：C11、上述三架构、Apple clang、
`-Wall -Wextra -Wpedantic`，Release 不得依赖未定义行为；Debug/WAE 必须包含
项目拥有的 `rtc_fatal_message.c` 兼容实现并通过 `-Werror`。更换 Xcode、SDK、clang、
最小闭包或 C 编译选项，必须重新生成 provenance、哈希、三架构构建和 harness 证据，
不能把本 probe 的结果移作新工具链的证明。

## 推荐决策与拒绝的替代方案

推荐**只 vendoring 官方仓库的最小 C 源码闭包**，由 `VoiceActivityDetectionKit` 的
production implementation target 私有封装，Swift 层仅通过现有
`VoiceActivityDetecting` actor port 暴露 `VoiceActivityObservation`。推荐源码而非
预编译产物，原因是可审计、可重建、可对三架构做相同 WAE 检查，并避免 XCFramework
切片/签名/来源不可见。

以下方案在本决策中拒绝：

1. **完整 WebRTC**：远超本地端点需要，扩大代码、构建、供应链、许可证和隐私审计面。
2. **第三方 Swift wrapper 或 CocoaPod**：引入额外维护者和转译边界；无法把上游闭包、
   编译参数和许可证责任收敛到本仓库。
3. **预编译静态库/XCFramework**：当前无法从产物反推出可审计的源文件闭包，且架构、
   bitcode/符号和签名元数据会成为额外发布风险。
4. **能量检测器或旧 amplitude timer 生产回退**：没有质量门禁，且会违反“本地确认
   起音后才上传”的隐私与产品语义；它们只能继续存在于 benchmark/test-support。

## 目标源码与头文件闭包

### 生产候选：11 个 upstream C + 1 个本地兼容 C

精确候选为 **11 个未修改 upstream C 文件，加 1 个项目拥有的兼容 C 文件（12 个 C
translation units）**。上游 11 个文件的哈希来自 `source-sha256.txt`；兼容文件的 probe 哈希为
`8c9a6ed5e648da7fc609a8e0b83f1f4a5ea78582d8ca6b0f302e5df1aae55cd3`。

| 来源 | 路径 | SHA-256 |
| --- | --- | --- |
| upstream | `common_audio/vad/webrtc_vad.c` | `e185a67f8cc1c03a005b24d3a144be237bcdfeb365ee2130f93a0edb81b7819a` |
| upstream | `common_audio/vad/vad_core.c` | `6d78d06869f0e85ef84cea4fa05397a6e7a8bfcd70ad415b39ba25de721706e3` |
| upstream | `common_audio/vad/vad_filterbank.c` | `e026f2b05183efe34b053d7c7fd53edd7637218afe7a2513ed001ffce0b515b0` |
| upstream | `common_audio/vad/vad_gmm.c` | `9ef9fdba74dd87acbd0a3cb90746a1049f33dac7ea1910387f542f73dfbd8876` |
| upstream | `common_audio/vad/vad_sp.c` | `2633f8c3abfb6bd3a5a852abc6ce8cdc1756b659f0ffa2a8617f8d536309c25d` |
| upstream | `common_audio/signal_processing/division_operations.c` | `2fec2e6baa1ad5ccf47be8e7bd5018fda3d269c381d8843d5ce76995baf3f36e` |
| upstream | `common_audio/signal_processing/energy.c` | `a4067e935332b8b759dd2bbb14b2e2783af1df6bb22f016fb13e35af0002fc48` |
| upstream | `common_audio/signal_processing/get_scaling_square.c` | `3cb27b5a9fc1715afa769fcca463e27f34075d4cac8770396e39aa64bba17539` |
| upstream | `common_audio/signal_processing/resample_48khz.c` | `56a9469c13fce3793d942143d92ca8d64fd66fc4e2162c59e741893db336b135` |
| upstream | `common_audio/signal_processing/resample_by_2_internal.c` | `556105d330f1025eaa706af776210d70c1c865d9cc84e863dd772a1a7c4ed9e4` |
| upstream | `common_audio/signal_processing/resample_fractional.c` | `a84430c582bcd4505b65fe6723adcd946aa5ddddb302bc0f4528a446b99c7e1e` |
| project-owned | `rtc_fatal_message.c`（probe 中为 `compat/rtc_fatal_message_compat.c`） | `8c9a6ed5e648da7fc609a8e0b83f1f4a5ea78582d8ca6b0f302e5df1aae55cd3` |

`rtc_fatal_message.c` 不是 WebRTC 文件。它只为 upstream C 的 `RTC_DCHECK` 回调提供
项目明确审计过的 fatal/diagnostic policy；接入前必须决定 release/debug 的行为、
线程安全和是否允许进入 App 二进制，不能因为 probe 能链接就默认接受。

### 14-vs-11 reconciliation

probe 的 `source-sha256.txt` 记录了 **14 个 upstream C 文件**。推荐生产闭包保留其中
**11 个未修改 upstream 文件**：5 个 VAD 文件、3 个通用 signal-processing 文件和
3 个重采样文件（`resample_48khz.c`、`resample_by_2_internal.c`、
`resample_fractional.c`）。probe 额外编译的 3 个 upstream 文件
`min_max_operations.c`、`resample_by_2.c`、`spl_init.c` 是本产品当前构建中不必要的
extras，因此不进入候选表；它们不应被误报为生产依赖。

三个保留的重采样文件仍然必要：即使产品输入固定为 16 kHz，未修改的 `InitCore`/
公开 API 对象仍引用 8/16/32/48 kHz dispatch 分支。移除这些文件只有通过 upstream
fork/源码修改才能链接，违反“未修改 upstream VAD objects”的目标，因此被拒绝。

所以数字含义是：**14 = probe 为验证未修改公开 API 而编译的 upstream closure；
11 upstream C + 1 local compatibility C = 推荐产品闭包（12 个 C translation units）**。
这 11 个 upstream 文件链接完整的未修改 upstream VAD objects，不依赖 dead-strip 假设，
也不需要裁剪或修改公开 API；产品输入仍按现有契约固定为 16 kHz/20 ms。

### 12 个候选头文件

以下是 production 候选的 12 个 upstream 头文件及哈希。它们覆盖保留的重采样实现；
probe-only 的 3 个 upstream extras 及其专属实现不自动进入产品。

| 路径 | SHA-256 |
| --- | --- |
| `common_audio/signal_processing/include/signal_processing_library.h` | `864364506ceb8afe96f2a5cb9c2c0746eb0f1c2450c95c2d8bd761e70319a5d5` |
| `common_audio/signal_processing/include/spl_inl.h` | `efe22cc6622fca9636a8fb9089b48e18d8503cab0151bb7dd096583bff2e75dd` |
| `common_audio/signal_processing/resample_by_2_internal.h` | `f4f84d87cbf1a544a2f16f9b72f3896ba8a6ba7e925daa83f4f3ff4ceb539358` |
| `common_audio/third_party/spl_sqrt_floor/spl_sqrt_floor.h` | `ba9fb284433f5dfa622e88d7a2f845cef1ccc820e1379816db006ec4dfbffd5c` |
| `common_audio/vad/include/webrtc_vad.h` | `6ae83e71dd1bfce6214a71817dd9e6f60e59f44a31c9b88650fad4b0808dc91e` |
| `common_audio/vad/vad_core.h` | `0fcbdb0a819e2f67b48d6e0c7a4731863a5394af0a74b63107775333f933a262` |
| `common_audio/vad/vad_filterbank.h` | `e69172ec0a2c3ca808166bcfc35e87ec5ef7f884a1b30400e038da8eca623bbc` |
| `common_audio/vad/vad_gmm.h` | `85a8a58e5b9af6cbbb30de276f17a01fc6a7e9334f8e2abe48152da3ed8301fb` |
| `common_audio/vad/vad_sp.h` | `7fc7e30b29b3c5f8cfcfa3334880186a012e3d896f41ca3edc0c956d4eb2c965` |
| `rtc_base/checks.h` | `aaa01bd24e537b581ac3cff43947ecc7d2d95fded7a16c5e5269fff22de24274` |
| `rtc_base/compile_assert_c.h` | `2356cc41c37f22f9b0fb94e4030bea7734dc670d7c98ee92c28b95f4ac3c13e5` |
| `rtc_base/sanitizer.h` | `bd59bcd852f9d2c84da3957852076e70717edcf403b5453ebda28302da7b33a1` |

以上哈希直接取 probe 的 `header-sha256.txt`。接入时应重新核对路径和文件内容；发现
任何上游漂移即停止构建并更新审批记录。

## 依赖边界与 App throwing factory

已新增只在 `VoiceActivityDetectionKit` 内可见的实现 target `WebRTCVoiceActivityDetection`，它不得改变现有
`VoiceActivityDetectionKit` 的公共 port，也不得让 `SingleGreenGlassesKit` 依赖 C、
AVFoundation、SwiftUI、Keychain 或 provider SDK。

`SingleGreenDemo` 仍是 composition root：它负责检测器配置、麦克风权限、音频 session、
factory 选择和用户可见 copy。factory 应是 throwing API，至少区分：

- `detectorUnavailable`：未编译该实现、架构不支持或功能开关关闭；
- `detectorInitializationFailed`：C context/mode/采样率初始化失败；
- `detectorPolicyRejected`：请求不符合产品固定的 16 kHz、20 ms 或 mode 范围；
- `dependencyIntegrityFailed`：来源/哈希/构建 provenance 不匹配。

这些错误应在 App resolver 中映射为 `ConversationPreparationFailure` 的安全静态文案；
核心 controller 不读取 C 错误原文，不持有 provider 配置，也不能把 factory 失败转成
“开始上传”。失败仍必须保持设置不可用和 PTT 兼容。

### Binary confidence semantics

当前 probe 生成的 archive/harness 只具有“**compile/link feasibility**”置信度：
它证明指定源码和编译器可产生 Mach-O 产物。它不具有“VAD quality”“speech accuracy”、
“false-positive/false-negative rate”“功耗”“录音隐私”“真机可用”或“ASR 端到端”
置信度。任何 release evidence 必须分别记录这些维度，不能用 archive 大小或 harness
通过替代质量/设备验收。

## 隐私与音频策略

生产 detector 只能消费内存中的 16 kHz、mono、Int16 little-endian、20 ms（320 samples /
640 bytes）帧。当前 Stage 2A 策略保持不变：300 ms bounded pre-roll、3-of-5 起音、
800 ms 尾部静音、20 s 最大段、15 s 无起音超时、bounded source/pending-upload queue，
且本地起音确认前不得打开 ASR transport。pre-roll 仅在内存中用于同一段音频，不能写盘、
进入日志、telemetry、crash payload 或 provider 请求之外的缓存。

VAD 观测只能产生布尔/粗粒度 observation；日志不得包含 PCM、转写、回答、凭证、工具
参数或 provider payload。取消、重置、切后台、中断、过载、detector 错误和 generation
失配必须丢弃未上传帧并阻止 stale rearm。引入 WebRTC 不改变这些 privacy invariants。

## Provenance manifest（接入时必须提交）

仓库应在实现变更中附带机器可校验的 manifest（路径和字段名可以复用现有 release
evidence 风格），最小 schema 如下：

```json
{
  "dependency": "webrtc-vad-minimal",
  "remote": "https://webrtc.googlesource.com/src",
  "commit": "<40-hex>",
  "commitDate": "<RFC3339>",
  "sourceFiles": [{"path": "<repo-relative>", "sha256": "<64-hex>", "upstream": true}],
  "headerFiles": [{"path": "<repo-relative>", "sha256": "<64-hex>", "upstream": true}],
  "projectFiles": [{"path": "<repo-relative>", "sha256": "<64-hex>", "upstream": false}],
  "legalFiles": [{"path": "LICENSE|PATENTS|AUTHORS", "sha256": "<64-hex>"}],
  "compiler": {"vendor": "Apple clang", "version": "<version>", "flags": ["..."]},
  "targets": ["arm64-apple-ios17.0", "arm64-apple-ios17.0-simulator", "x86_64-apple-ios17.0-simulator"],
  "artifactSha256": [{"target": "<triple>", "path": "<artifact>", "sha256": "<64-hex>"}],
  "apiInput": {"sampleRateHz": 16000, "frameMs": 20, "sampleCount": 320},
  "generatedAt": "<RFC3339>",
  "verification": {"quality": "not-run", "device": "not-run", "realService": "not-run"}
}
```

Manifest 的 `sourceFiles` 不得把 14-file probe 的临时产物误写成 11-file production
closure；如果采用完整多采样率公开 API，必须显式增加文件并更新 schema 记录。

## 法务/来源清单（未决，不构成法律意见）

probe 已核对上游根目录的 `LICENSE`、`PATENTS`、`AUTHORS`，哈希如下；接入前必须把
这三份文件按上游版本完整保留在仓库的第三方声明目录，并由负责人完成许可证/专利审查。

| 文件 | SHA-256 |
| --- | --- |
| `LICENSE` | `ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482` |
| `PATENTS` | `01462e2068d1a04c2274f3389773014c14ed9bc3446b28303543bd3e3c064145` |
| `AUTHORS` | `8f2721d288f65f4dee92c5794b1d7c084649c76c78923b83f089723f114e120f` |
| `common_audio/third_party/spl_sqrt_floor/spl_sqrt_floor.h` | 已列于候选头文件哈希表；其上游许可/归属必须随文件审查 |

当前 `NOTICE.md` 仍反映仓库本身没有选定通用许可证；WebRTC 接入不能被解释为仓库已
完成整体许可证选择，也不能只保留 LICENSE 而省略 PATENTS/AUTHORS 或 SPL 归属。

## 接受矩阵

| 门禁 | 必须证明 | 当前状态 |
| --- | --- | --- |
| 审批 | 本文复核并勾选批准框 | **已完成（用户批准）** |
| 来源闭包 | 11 upstream C + 1 local compatibility C + 12 upstream headers 及哈希一致 | **已完成**；commit `1e7f4c3c39e1aacaf8884452f80cd82749b1f8f1`，tree `9e1c...` |
| Apple-Clang | 三架构、C11、WAE、无警告 | **已完成**；Debug/Release simulator 与 unsigned Release iphoneos pass |
| C fatal policy | `rtc_fatal_message.c` 行为经安全/并发审查 | **已完成**；project-owned compatibility C |
| Swift boundary | 仅实现 target 依赖 C；public kit 与 core 仍 provider-neutral | **已完成**；11 hidden wrappers + 1 facade C + 1 public header，raw C 不直接编译 |
| factory | App throwing factory 与安全错误映射、缺失时 fail closed | **已完成**：production root non-nil、arm 前 inert、mode 2 `.aggressive`；PTT bypass |
| deterministic unit | mode、非法帧、reset/cancel/generation、C error 映射 | **已完成**；VAD ASan/UBSan/TSan 各 43/43 |
| performance | 三架构 release benchmark：CPU、内存、每帧耗时、功耗代理指标 | 未运行 |
| corpus quality | 许可清晰的真实/合成语料，报告 precision/recall、FPR/FNR、端点延迟，并按噪声/口音/设备分层 | 未运行 |
| privacy | pre-roll 不落盘、不泄露，起音前无 ASR upload，日志扫描通过 | 框架已有策略；production detector 未实现 |
| App regression | 六 Package 与 App 全量门禁保持当前证据 | **377/377、62/62**；App `/private/tmp/SingleGreenDemo-QA-PostWrapper-AppTest.xcresult`，ASR/controller 24/24、77/77 |
| device | 真机麦克风权限、起音、尾静音、误触发、蓝牙/有线路由、后台/中断 | **部分完成**：2026-08-28 13:29 解锁后 launch 成功，PID 5053 稳定；用户报告真机测试“没什么问题”。仍非完整脚本化 VAD/service 矩阵 |
| release | signed build/install/launch 分别记录，真实 ASR/服务另行记录 | 既有部署证据不等于 VAD 功能证据 |
| legal | LICENSE/PATENTS/AUTHORS/SPL 归属和 NOTICE 完整 | **已完成**；5 个法律/provenance 文件已随 vendored 闭包保留 |
| rollback | 可关闭 factory/feature flag 并恢复 PTT，演练记录 | 未演练 |

### Performance、corpus 与人工设备门禁

性能必须在三架构 release-style 产物上使用固定帧回放，至少报告 p50/p95/p99 单帧
耗时、CPU 时间、峰值内存和长时间运行期间的队列水位；不得用 host harness 的一次
运行推断手机指标。质量语料必须有合法来源、版本和分层标签；square-wave 或全零
fixture 只能验证 API/边界，不能计入 speech accuracy。

人工设备 gate 至少包含：首次权限拒绝与重新授权、安静/正常语速/连续两轮、短暂停顿、
800 ms 端点、20 s 上限、环境噪声、误触发、蓝牙/有线切换、来电/音频中断、前后台、
锁屏，以及“起音前没有 ASR 上传”的网络观察。每项分别记录设备、系统、版本、时间和
结果；不能用已通过的签名安装/启动证据替代。

## 批准后的迁移步骤

1. 勾选本文审批框，创建实现任务并冻结 commit、source/header/legal 哈希。
2. 将 11 upstream C + 1 local compatibility C + 12 upstream headers 纳入独立实现
   target（如要保留 probe 的 3 个 extras，必须另行批准并记录为 14 upstream C + 1 local C），保留
   上游文件原样；加入项目-owned `rtc_fatal_message.c` 和来源说明。
3. 实现最薄 C adapter 与 actor detector，严格转换 mode、sample rate、frame length
   和 C return code；不把 raw C 错误或 PCM 传到 UI/telemetry。
4. 在 App composition root 实现 throwing factory、权限/设置 gating 和
   `ConversationPreparationFailure` 映射；缺失、初始化失败或哈希不符均 fail closed。
5. 先跑 VAD package focused tests，再跑六 Package strict gate、App XCTest、三架构
   build、静态 secret/privacy/license gates；生成 provenance manifest。
6. 完成 benchmark/corpus 报告与 code review，修复 P0–P2 后重新跑全量门禁。
7. 构建、签名、安装、启动分别记录；随后按接受矩阵在真机完成人工 VAD/ASR 观察，
   不把真实服务结果与本地检测结果混写。

## 回滚

任何 provenance mismatch、C fatal policy 未审查、质量/性能未达阈值、privacy gate
失败或真机误触发都应关闭 production detector factory/feature flag，恢复当前 PTT
路径和“本地语音检测暂不可用”文案。回滚不得删除历史 provenance 或改写历史任务记录；
应追加新的 evidence record，保留历史 351/351、58/58 基线及本次失败原因。若未来
升级 WebRTC commit，按全套审批、哈希、三架构、法律、benchmark、corpus 和设备流程
重新执行，不能热替换单个 C 文件。

## 当前明确非结论

- WebRTC 最小源码闭包已纳入并由 `SingleGreenDemo` composition root 链接；这不表示整个仓库采用 WebRTC 许可证。
- production detector 已实现并通过本地编译/测试门禁；真机已完成用户观察验收，但仍缺完整脚本化 VAD、ASR/service 矩阵。
- `/private/tmp/webrtc-vad-feasibility.XSG7a1/` 的 harness 不是 speech corpus，也不代表
  VAD 质量或误触发率。
- 麦克风修复工作树首次 launch 因锁屏短暂阻断；解锁后于 2026-08-28 13:29 launch 成功，PID 5053 稳定。该命令证据与用户“真机测试没什么问题”的观察分别记录，不等同完整脚本化矩阵。
- 本 ADR 的当前证据为六 Package **377/377**、App **62/62**；真机 launch/PID 稳定且用户观察无明显问题，但不替代完整真实 VAD/mic/ASR/LLM/Search 矩阵
  或 UI 功能。
