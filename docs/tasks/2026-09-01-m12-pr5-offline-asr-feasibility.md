# M12-PR5 离线 ASR 可行性 Spike

## 1. 当前结论

M12-PR5 选择 **Apple 系统离线语音能力优先、whisper.cpp 暂缓**的验证路线。当前仅在 `Internal` 构建中加入一个手动能力探针，用于查询中文 locale、模型资产状态、兼容音频格式，并在资产已安装时测量模型准备耗时。

这不等于产品已支持离线 ASR。当前没有自动下载模型、没有录音、没有转写、没有将系统实现接入对话或提词器，也没有取得真机性能与准确性数据。

## 2. 候选方案判断

### 2.1 Apple 系统能力：优先验证

Apple 在 [WWDC25 《Bring advanced speech-to-text to your app with SpeechAnalyzer》](https://developer.apple.com/videos/play/wwdc2025/277/) 中介绍了 iOS 26 的 `SpeechAnalyzer` / `SpeechTranscriber`：转写在设备端执行，支持按 locale 查询与管理系统模型资产。项目当前最低系统为 iOS 26，本地 Xcode 26.5 SDK 已暴露所需 API，因此可以先不引入第三方依赖地取得真机基线。

系统模型由 `AssetInventory` 管理，不直接计入 App 包体积；但本轮没有下载或测量任何资产，因此不给出数值化模型体积结论。是否支持中文、资产是否可用以及首次准备开销，均必须在目标真机上实测。

### 2.2 whisper.cpp：保留为备选

[whisper.cpp 官方仓库](https://github.com/ggml-org/whisper.cpp) 提供 Apple 平台实现；其 [iOS 示例说明](https://github.com/ggml-org/whisper.cpp/blob/master/examples/whisper.swiftui/README.md) 需要引入 XCFramework 并携带模型资源。这会引入新的产品依赖、App/资源体积和设备性能决策，所以在 Apple 方案的真机基线出来前不进入项目依赖。

## 3. 本轮实现边界

- 代码只在 `INTERNAL_DIAGNOSTICS` 下编译，User 构建不包含 UI、类型或测试。
- 手动入口位于「Debug 与日志」面板，不在启动或后台自动运行。
- 请求 locale 固定为 `zh-CN`；记录系统解析后的 locale、可用性、资产状态、采样率、声道数、准备结果与耗时。
- 只有当资产状态已是 `installed` 时才调用 `prepareToAnalyze`；不触发资产下载。
- 不请求麦克风权限，不开启音频采集，不产生或保存转写。
- 日志是白名单字段，不包含语音、转写、用户内容、API Key 或原始错误 payload。
- 构建产物门禁要求 Internal 必须包含 `offline_asr_capability_check_button`，User 发现同一 marker 必须失败。

## 4. 当前自动化证据

| 门禁 | 结果 | 证明范围 |
| --- | --- | --- |
| 离线能力探针聚焦测试 | 2/2 | 状态映射与隐私安全日志格式 |
| `SingleGreenInternal` App Simulator | 135/135 | Internal 编译与 App 回归 |
| `SingleGreenUser` App Simulator | 100/100 | User 无内部测试与行为回归 |
| User Release Simulator | 通过 | arm64 + x86_64 优化构建 |
| Internal Debug / Release Simulator | 通过 | arm64 + x86_64 的 Internal 编译 |
| 构建变体正反向 fixture | 41/41 | Internal 含探针、User 不含探针 |
| 新鲜 User Release 产物隔离扫描 | 通过 | 不含内部诊断/离线 Spike marker |
| 新鲜 Internal Debug 产物能力扫描 | 通过 | 内部入口与已评审能力已链接 |
| 新鲜 Internal Release 产物能力扫描 | 通过 | 优化后仍保留必要能力 marker |
| privacy / secret / repository hygiene / diff whitespace | 通过 | 静态隐私与仓库门禁 |

xcresult：

- 聚焦测试：`/tmp/SingleGreenDemo-M12-PR5-OfflineProbe/Logs/Test/Test-SingleGreenInternal-2026.09.01_14-52-03-+0800.xcresult`
- Internal 全量：`/tmp/SingleGreenDemo-M12-PR5-InternalFull/Logs/Test/Test-SingleGreenInternal-2026.09.01_14-54-38-+0800.xcresult`
- User 全量：`/tmp/SingleGreenDemo-M12-PR5-UserFull/Logs/Test/Test-SingleGreenUser-2026.09.01_14-56-04-+0800.xcresult`

### 4.1 Build 11 真机交付检查点

- `SingleGreenInternal` / `Internal-Debug` 以命令行覆盖版本号的方式归档为 `0.1 (11)`，未修改项目内默认 Build 10 版本配置。
- IPA：`../../../测试包/Build-11-M12-PR5-Internal/SingleGreenInternal-Debug-Build11-M12-PR5.ipa`。
- 包身份：`com.local.SingleGreenDemo.internal`，显示名「单绿内部版」，iphoneos arm64，Apple Development 签名，Team `JZK35JTQH6`。
- 归档和导出包的 `codesign --verify --deep --strict` 与 Internal 能力扫描均通过；当前连接设备 UDID 包含在 provisioning profile 中。
- IPA 大小 3,910,574 bytes；SHA-256 `b472e6a8525975f6c7e934c649355f6db8bb0255b5f6c4fac4b45935ed308ab4`。
- 已覆盖安装到 iPhone 17 Pro Max；安装前设备清单为 Build 10，安装后设备清单确认 `0.1 (11)`。
- 本轮未启动 App，也未点击能力探针；因此安装成功不是中文支持、模型状态或准备耗时证据。

## 5. 真机测量矩阵

| 指标 | 方法 | 当前状态 |
| --- | --- | --- |
| 中文 locale 可用性 | 真机手动点击探针，记录 resolved locale | 未验证 |
| 系统模型资产状态 | 分别记录未安装与已安装状态 | 未验证 |
| 模型体积 | 以系统资产占用为证据，不冒充 App 包体积 | 未测量 |
| 首次/热启动准备 | 冷启动与第二次分开记录 `prepareToAnalyze` | 未测量 |
| 中文准确性 | 固定、脱敏、可重复的中文短句/长文样本，统一 WER/CER 规则 | 未实现 |
| 首字/首个 final 延迟 | 固定音频和起止时钟 | 未实现 |
| 峰值内存 | Instruments/OS 指标，区分 App 进程与系统资产 | 未测量 |
| 功耗与温升 | 固定 15/30 分钟转写负载，记录电量、thermal state 与环境 | 未测量 |
| 最低设备 | 至少覆盖当前目标高/中/低档机型 | 待确认（责任方未指定） |

## 6. 下一步完成门

1. [x] 经独立授权生成并安装包含本 Spike 的 Build 11 Internal 真机包。
2. [ ] 先运行无下载能力探针，只记录上表的非内容字段。
3. [ ] 如需下载 Apple 模型资产，必须增加明确的用户触发与进度/失败状态，不放入自动启动路径。
4. [ ] 评审固定中文基准素材和记分方法后，再增加录音/转写实验；转写和音频不进入默认日志或发布证据。
5. [ ] 完成真机矩阵后，再决定继续 Apple 方案、进入 whisper.cpp 对照，或终止离线 ASR 路线。
