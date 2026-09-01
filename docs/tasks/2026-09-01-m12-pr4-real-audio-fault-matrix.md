# M12-PR4 真实音频故障矩阵

## 1. 当前结论

M12-PR4 已建立可执行矩阵，但真实音频与网络故障场景尚未完成。2026-09-01 已确认 Build 10 可以安装并从本次安装路径启动；音频 Core 聚焦自动化 92/92、Feature/生命周期聚焦 156/156、Adapter 聚焦 16/16、App 麦克风租约 4/4，共 268/268 通过。上述证据证明注入事件与跨层状态契约，不等于内置麦克风、Bluetooth HFP、有线输入、系统抢占、真实网络或真实 ASR 已通过。

因此，本检查点不调整生产恢复策略：PTT 与 Voice Activated 的自动恢复预算继续为 0，不填写未经实测的重试次数、超时、退避或抢占优先级。

当前 Build 10 是 `SingleGreenUser` 的 User Release 产物，按发布安全边界使用 fail-closed 的服务端凭证 transport 和 speech credential provider；它不会编译或读取演示凭证。当前仓库尚未提供可用的服务端短期凭证端点，所以该包可以完成部署/启动验证，但不能建立真实 ASR Session，也不能完成本矩阵的真实 capture → transport 闭环。这是预期的发布安全行为，不是安装失败。

继续执行真机音频矩阵有两条路线：

1. 生成并安装仅用于内部实验的 Internal 测试包，由用户在设备本地输入非生产测试凭证；凭证不得进入仓库、日志或证据；该路线已于 2026-09-01 获授权，并完成 Internal Debug 包的生成、核验和安装，启动仍待独立授权；
2. 实现并完成安全评审的服务端短期凭证端点，让 User Release 通过生产契约获取临时 lease。

## 2. 候选包与部署证据

| 项目 | 结果 |
| --- | --- |
| Commit | `d4c15aa02537d31ee49ded759e5a118123ac8ce5` |
| IPA | `测试包/Build-10-M12/SingleGreenUser-Build10-M12.ipa` |
| 身份 | `com.local.SingleGreenDemo`，`0.1 (10)`，iphoneos arm64，Apple Development |
| SHA-256 | `cc4b3edbe34006d0a7dba0b856c746c343a064c781b4390ed90ab49d82b8321c` |
| 设备 | iPhone 17 Pro Max |
| 安装 | 通过；设备应用清单显示 `0.1 (10)` |
| 启动 | 通过；2026-09-01 14:19（Asia/Shanghai），本次安装路径进程 PID 49477 |
| 启动说明 | 首次尝试因设备锁定被系统拒绝；解锁后重试成功。设备随后再次锁定，未取得长时驻留证据；旧安装路径的既有进程不作为 Build 10 证据 |

部署结果只证明包可安装并启动，不证明麦克风权限、采集、VAD、传输、Feature、UI、真实服务或物理眼镜体验。

### 2.1 Internal 真机实验包

| 项目 | 结果 |
| --- | --- |
| 配置 | `SingleGreenInternal` / `Internal-Debug` |
| IPA | `测试包/Build-10-M12-Internal/SingleGreenInternal-Debug-Build10-M12.ipa` |
| 身份 | `com.local.SingleGreenDemo.internal`，显示名“单绿内部版”，`0.1 (10)`，iphoneos arm64 |
| SHA-256 | `f7a996c5993a1328fff7f4378c85566a2e11edc86188f14ca3f0d6a350ba7cd0` |
| 能力门禁 | 通过；内部诊断、本地演示凭证入口、Keychain helper 与三类凭证 UI 标记齐全，未嵌入 XCTest |
| 签名 | Apple Development；App 与 provisioning Team 一致，当前设备在 `ProvisionedDevices` 中 |
| 安装 | 通过；设备应用清单显示 `com.local.SingleGreenDemo.internal` 为 `0.1 (10)` |
| 启动 | 未执行；当前安装路径无运行进程，等待独立授权 |

第一次尝试的 `Internal-Release` 产物未安装：真实 Keychain 调用已编入，但 Release 优化移除了现有扫描器依赖的 `KeychainHelper` 类型名字符串，导致内部能力门禁 fail-closed。为本轮可诊断的实验矩阵改用 `Internal-Debug`，没有绕过门禁。若未来要交付 Internal Release，应先把该扫描证据改为优化后仍稳定的契约并补回归测试。

### 2.2 用户观察结果

2026-09-01，用户反馈已在真机测试 Internal Build 10，整体“比较 ok”。该反馈可作为本候选包的用户观察冒烟证据，但没有提供测试步骤、音频路由、网络条件、诊断记录或 capture/VAD/transport/Feature/UI 分层结果，因此：

- 不把该反馈扩写为真实普通话 ASR、提词器跃迁、蓝牙、有线、系统抢占、route change、media-services reset、前后台或网络切换通过；
- 不据此填写下方任一故障矩阵行；
- 不据此调整生产自动恢复预算、超时或退避；
- 后续若补充逐项场景，可在不记录凭证、音频和转写的前提下追加结果。

## 3. 自动化基线

执行：

```bash
swift test --package-path Packages/VoiceChatCore \
  --filter 'AudioCapture|PCMFrameSource|AudioCaptureFailureMapping|VoiceActivatedASRSession|ASRSessionSupervisor'
```

结果：92/92，0 failures。

| 边界 | 数量 | 已证明的范围 |
| --- | ---: | --- |
| `AudioCaptureTests` | 21/21 | AudioSession 激活顺序、start/stop 幂等、通知订阅、陈旧 run 拒绝、隐私安全粗粒度事件 |
| `PCMFrameSourceTests` | 7/7 | 20 ms 帧、旧回调拒绝、缓冲区溢出、系统音频事件终止语义 |
| `AudioCaptureFailureMappingTests` | 1/1 | interruption/route/media reset 到 provider-neutral 类型化失败的映射 |
| `VoiceActivatedASRSessionTests` | 47/47 | capture/VAD/transport 生命周期、无帧 watchdog、中断与连接故障的一次终态 |
| `ASRSessionSupervisorTests` | 11/11 | 恢复资格、预算耗尽、已发布内容后禁止恢复、旧 Session retirement barrier |
| `VoiceActivatedASRSessionSupervisorTests` | 5/5 | 起音前恢复、起音后 fail-closed、旧事件拒绝 |

这些测试使用 fake source、fake transport 与注入事件，不会调用真实服务，也不验证物理路由、音质、延迟、功耗或温升。

跨层补充结果：

- `SingleGreenGlassesKit` 的 Conversation/Teleprompter/Host Lifecycle 聚焦测试 156/156；
- `SingleGreenConversationAdapters` 的 ASR Adapter 聚焦测试 16/16；
- `SingleGreenDemoTests/MicrophoneLeaseCoordinatorTests` 4/4，xcresult：`/tmp/SingleGreenDemo-M12-PR4-AppTests/Logs/Test/Test-SingleGreenUser-2026.09.01_14-22-16-+0800.xcresult`。

上述 176 项补充测试证明 Feature 降级、前后台代际、Adapter 终态映射和进程级麦克风租约的确定性行为，仍不替代真机观察。

## 4. 真机执行矩阵

状态定义：`待执行` 表示尚无真机结果；`不具备` 表示当前没有相应硬件或系统注入条件。每一格都必须来自同一次场景的实际观察，不能由自动化结果代填。

| 场景 | 操作/故障注入 | Capture | VAD | Transport | Feature | UI 最终状态 | 当前状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 内置麦克风基线 | 启动一次 PTT 与一次 Voice Activated 普通话话语 | 未测 | 未测 | 未测 | 未测 | 未测 | 用户反馈整体比较 ok；因步骤与分层结果未记录，仍待结构化复验 |
| Bluetooth HFP 启动 | 连接支持 HFP 的耳机后开始识别 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要 HFP 设备 |
| Bluetooth route change | 识别中连接/断开 HFP | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要 HFP 设备 |
| 有线/USB 输入 | 连接兼容输入后开始识别 | 未测 | 未测 | 未测 | 未测 | 未测 | 不具备时保持未验证 |
| 电话/其他 App 抢占 | 识别中触发系统音频中断，再结束中断 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要第二设备或可控 App |
| route change | 识别中改变输入路由 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行 |
| media services reset | 识别中触发系统 media services reset | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要可审计注入条件 |
| App background/active | 识别中退到后台，再回前台 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行 |
| Wi-Fi → 断网 | 建链前与建链后分别关闭网络 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行 |
| Wi-Fi ↔ 蜂窝 | 识别中切换网络 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要可用蜂窝网络 |
| 弱网/超时 | 在可控网络条件下制造超时 | 未测 | 未测 | 未测 | 未测 | 未测 | 待执行，需要网络调节条件 |

## 5. 每一场景的记录规则

每行执行时只记录以下非敏感事实：

1. Candidate commit、App 版本、设备型号、系统版本、场景开始时间；
2. capture 是否开始/停止、是否收到粗粒度系统事件；
3. VAD 是否进入起音/静音终点，不保存音频或转写；
4. transport 是否未打开、已打开、取消或类型化失败；
5. Feature 是否回到手动模式、可重试失败或安全空闲态；
6. UI 是否只出现一次明确终态，前台恢复后是否没有自动重启采集；
7. 是否出现麦克风重叠、迟到事件、重复内容或卡死。

不得把凭证、音频、转写、供应商 payload、路由设备名称或稳定设备标识写入证据。

## 6. 通过判定与后续决策

- 每个已执行场景必须同时得到 capture、VAD、transport、Feature 和 UI 五层结果；缺任一层就保持“部分验证”。
- 系统中断、route change 和 media reset 必须得到 provider-neutral 类型化失败或明确取消，且只有一个终态。
- App 进入后台必须取消未提交工作；回到前台不得自动恢复采集。
- 已发布非空内容、已接受起音或进入 finalizing 后，不得自动换 Session。
- 只有在内置麦克风、至少一个真实网络切换、至少一个系统音频故障均有重复结果后，才评审是否把恢复预算从 0 调高。
- Bluetooth、有线或 media reset 若缺少硬件/注入条件，应明确保留“未验证”，不阻碍记录其他场景，但不能宣称 M12-PR4 完成。
