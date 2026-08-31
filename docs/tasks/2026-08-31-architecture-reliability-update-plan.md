# 单绿眼镜平台架构、高可用与高可信 Update Plan

## 1. 文档状态

| 项目 | 内容 |
| --- | --- |
| 文档类型 | 详细实施计划 / 跨模块技术与产品路线 |
| 当前状态 | In progress：M10-PR1 已完成；M10-PR2 本机可执行门禁已完成，锁定工具链复验待补；M10-PR3 测试包已生成，真机体验待用户执行；M11-PR1 已完成本机实现；M11-PR2 手机端一次性撤销及本机最终门禁已完成，锁定工具链审阅待补 |
| 适用范围 | `SingleGreenDemo`、七个本地 Package、User/Internal 构建、未来真实眼镜 Host |
| 起始基线 | 当前 M9 之后的工作树，包含尚未提交的提词器“向后 50 个规范化字符内唯一精确命中跃迁”改动 |
| 目标读者 | 产品、架构、iOS、算法、QA、发布与设备验证参与者 |
| 负责人 | 待确认（责任方未指定） |
| 计划日期 | 待确认 |

本文从既有 M1–M9 路线继续，不修改历史里程碑证据。本文将原有“可复现工程、供应商可替换、真实设备质量、平台产品化”方向拆成可独立评审、实现、验证和回滚的 M10–M17。

状态说明：

- `已实现`：当前代码中存在，并有与该实现相匹配的代码或自动化证据；
- `历史证据`：曾在旧快照通过，不能替代当前工作树复验；
- `本地验证`：只证明本机代码、构建或模拟器结果；
- `提案`：本计划建议实施，尚不是当前产品能力；
- `待确认`：缺少产品、技术、设备或交付决策；责任方未指定时不推断负责人。

## 2. 总目标

将当前“功能丰富且测试较强的内部 Demo”升级为以下三层能力：

1. **高内聚、低耦合的平台内核**：新增或替换 Experience、ASR、LLM、搜索、显示设备时，不修改无关模块。
2. **可降级、可恢复的用户体验**：云端、网络、音频或单个工具失败时，用户仍能完成可接受的核心任务。
3. **证据可追踪的可信系统**：每项能力分别保留代码、集成、App、真机、眼镜和生产证据，不能用低层证据替代高层验收。

目标用户和主场景：

- 内部产品与研发使用 iPhone VST 验证不同单绿眼镜应用；
- 测试人员使用可重复脚本验证提词、对话、字幕、导航和显示 Profile；
- 未来真实眼镜 Host 复用同一 Feature 与 HUD 领域逻辑，只替换输入、渲染、设备和供应商 Adapter；
- 提词用户在云端 ASR 不可用时，仍能继续手动阅读和恢复位置。

## 3. 当前基线

### 3.1 已确认的架构事实

- App 是 Composition Root，当前注册 System Status、Navigation、Notification、Caption、AI Conversation、Text Adventure 和 Teleprompter 七个 Experience。
- 主链路为 `DemoEvent / 外部事件 → Experience 状态 → HUDScene → Renderer + DisplayProfile → VST 预览`。
- 当前有七个本地 Swift Package：`SingleGreenGlassesKit`、`VoiceChatDomain`、`VoiceChatCore`、`LLMKit`、`StreamingTextKit`、`VoiceActivityDetectionKit` 和 `SingleGreenConversationAdapters`。
- `SingleGreenGlassesKit` 仍同时承载 HUD 领域、Experience Runtime、内置 Experience、AI 对话编排、文字冒险和提词器。
- `VoiceChatCore` 同时承载 ASR 状态机、Voice Activated ASR、AVFoundation 音频采集和部分平台生命周期适配。
- `LLMKit` 同时承载通用 LLM/Agent 契约和博查搜索具体实现。
- User/Internal 构建通过不同 Bundle ID 和 capability flags 隔离内部诊断与本地演示凭证入口。

### 3.2 当前提词器事实

- 已有 `TeleprompterScript`、`TeleprompterScriptAligner`、纯值 `ReadingPositionEngine`、`TeleprompterController`、HUD Mapper 和 Experience。
- `ReadingPositionEngine` 接收脚本版本、锚点、转写片段、partial/final 语义和数值稳定证据，输出不含文本的 `stay / advance / jump` 决策；Controller 只负责会话代际、生命周期和应用决策。
- 当前工作树已实现：从当前已读位置向前最多 50 个规范化字符搜索，唯一精确的 ASR 后缀命中可单事件跃迁；重复目标、窗口外目标和低可信目标保持当前位置。
- “50 个字符”当前只计算字母、数字和 CJK；标点、空格、换行和 emoji 不占窗口。
- 当前已具备自动化覆盖，但真实普通话、真实网络、真机音频和物理眼镜体验仍待验证。
- 位置 checkpoint、删除闭环、TXT/Markdown 导入、长稿索引和离线评测集仍未完成；最近一次自动跃迁的手机端一次性撤销已实现。

### 3.3 证据基线

- 同一工作树最近一次 SingleGreenGlassesKit 为 256/256，SingleGreenUser App Simulator 为 86/86。
- 当前架构 inventory、import boundary 和 11 个负向 fixture 已通过。
- 当前机器为 Xcode 26.5 / Swift 6.3.2，仓库锁定 Xcode 26.6 / Swift 6.3.3；公共 API 基线必须在锁定工具链重新执行。
- 七个 Package 的覆盖率表属于此前测量基线；最新提词器变化后应重新测量受影响 Package，不能直接把历史数字作为当前结果。
- 已生成并核验内部测试 IPA；生成、安装、启动、真实功能验收仍是不同门禁。

### 3.4 M10 当前执行快照（2026-08-31）

- `M10-PR1`：已完成 50 个规范化字符内的唯一精确跃迁，并修复重复目标可能从普通进度路径旁路前进的问题；partial 与 final 共用相同歧义保持规则。
- Core 聚焦测试 37/37、`SingleGreenGlassesKit` 全量 242/242、`SingleGreenUser` App Simulator 85/85 均通过。
- 七个 Package 在 complete strict concurrency + warnings-as-errors 下共 538/538 通过；`VADBenchmark` 与 `ASRCLI` 产品构建通过。
- User Release Simulator build、Internal Debug Simulator build 与内部能力扫描通过；架构边界、11 个负向 fixture、secret、repository hygiene、privacy logging 和 VAD privacy 门禁通过。
- 公共 API updater 安全自检通过；实际八模块双架构 API baseline 因本机不是锁定工具链而按设计 fail-closed，尚未复验。
- `M10-PR3` 测试产物为 `测试包/Build-9-M10/SingleGreenInternal-Build9-M10.ipa`：版本 0.1（9），内部 Bundle ID 与能力标记核验通过，SHA-256 为 `6940e987a677154b69edfaf43c1951ad7ca69552aadd41a6546f573aed660505`。该记录只证明 archive/export/sign/package identity，不代表 install、launch、真实 ASR 或眼镜体验通过。

### 3.5 M11-PR1 当前执行快照（2026-08-31）

- 已在现有 `SingleGreenGlassesKit` 内新增纯值 `ReadingPositionEngine`，未新建 Package/Target；保留 `TeleprompterScriptAligner` 与 Controller 的 `aligner:` 初始化入口以降低源兼容风险。
- `TeleprompterScript` 新增确定性版本标识；该标识仅用于拒绝陈旧脚本事件，不是加密摘要，也不能用于恢复原稿或跨系统身份判断。
- Engine 输入显式携带脚本版本、当前位置、partial/final 语义与仅含数值的稳定证据；输出的 reason/evidence 只有枚举和数值，不携带稿件、转写或供应商 payload。
- Controller 不再持有匹配阈值、候选稳定计数或跃迁判定；它只把识别事件映射为 Engine 输入，并应用 `stay / advance / jump` 的目标位置。
- 新增 Engine 聚焦测试 8/8；原提词器聚焦回归 37/37；`SingleGreenGlassesKit` 全量及 strict-concurrency/WAE 均为 250/250；七 Package strict-concurrency/WAE 共 546/546；SingleGreenUser App Simulator 85/85；User Release generic iOS Simulator build、架构边界/负向 fixture、隐私、secret、repository hygiene 与 API updater 安全自检均通过。
- 本批次在 Xcode 26.5 / Swift 6.3.2 完成本地验证；仓库锁定 Xcode 26.6 / Swift 6.3.3，因此新增 public API 的最终 baseline 生成与差异审阅仍按设计阻塞。未执行 live provider、物理设备、真实眼镜或生产验证。

### 3.6 M11-PR2 当前执行快照（2026-08-31）

- Core 新增不含稿件或转写的一次性 `ReadingPositionUndoState`；记录绑定脚本版本、独立定位代际和跃迁前后锚点，只有已应用且未完成的自动 `.jump` 可创建。
- Controller 消费撤销前先使记录失效，取消当前 Session，恢复跃迁前锚点，并在原先处于跟随态时建立全新 Session；重复点击和旧 partial/final 均不能再次改变位置。
- 手机控制面板仅在当前选择提词器且记录仍可消费时显示“撤销刚才的自动跳转”；眼镜四向键映射未改变。
- Engine 聚焦 9/9、提词器聚焦 42/42、`SingleGreenGlassesKit` 严格并发/WAE 全量 256/256、七 Package 严格并发/WAE 共 552/552、SingleGreenUser App Simulator 86/86 均通过；User Release generic iOS Simulator build、7-Package inventory、架构边界与 11 个负向 fixture、隐私、secret、repository hygiene、diff whitespace 和 API updater 安全自检通过。
- App 证据：`/tmp/SingleGreenDemo-M11-PR2-Final-AppTests/Logs/Test/Test-SingleGreenUser-2026.08.31_22-51-58-+0800.xcresult`，iPhone 17 Pro / iOS 26.5，0 failures，0 skips。
- 实际 public API baseline 已尝试并按设计 fail-closed：当前 Xcode 26.5（17F42）/ Swift 6.3.2 低于锁定 Xcode 26.6（17F113）/ Swift 6.3.3，未生成或改写 baseline。未执行设备安装/启动、真实 ASR、物理眼镜或生产验证。

## 4. 本计划的边界

### 4.1 纳入范围

- 提词器定位、跃迁、恢复、导入和评测；
- Feature、Runtime、HUD、ASR、LLM、搜索与平台 Adapter 的模块重构；
- 音频/网络故障隔离、重试、恢复和降级；
- HUD 视觉回归和 DisplayProfile 兼容矩阵；
- 隐私安全遥测、指标基线和发布证据；
- 未来真实眼镜 Host 的契约和接入顺序；
- CI、API 兼容、覆盖率、真机和长时间稳定性验证。

### 4.2 当前不承诺

- 不承诺具体完成日期、投入人数或成本；
- 不把本计划视为真实眼镜参数、量产能力或生产 SLA；
- 不在没有基线数据前承诺误跃迁率、延迟、功耗或可用率目标；
- 不要求一次性引入 TCA、OpenTelemetry、whisper.cpp 或其他第三方依赖；
- 不采用运行时下载第三方代码的插件体系；
- 不在本计划中自动执行 commit、push、设备安装、设备启动或发布。

## 5. 目标依赖结构

```text
App Hosts
├── SimulatorHost
└── RealGlassesHost                         Future
    │
    ▼
Feature Composition
├── TeleprompterFeature
├── ConversationFeature
├── TextAdventureFeature
├── CaptionFeature
├── NavigationFeature
└── NotificationFeature
    │
    ▼
Platform Contracts
├── ExperienceRuntime
├── HUDDomain
├── DisplayProfileDomain
├── InputRouter
└── DiagnosticsAPI
    │
    ▼
Capability Cores
├── ASRDomain
├── VoiceActivatedASR
├── VADCore
├── LLMCore
├── AgentCore
├── StreamingTextKit
└── ReadingPositionEngine
    │
    ▼
Infrastructure Adapters
├── AudioCaptureApple
├── VolcengineASRAdapter
├── OpenAICompatibleTransport
├── BochaSearchAdapter
├── KeychainCredentialAdapter
├── InternalDiagnosticsAdapter
└── RealGlassesDeviceAdapter                 Future
```

### 5.1 强制依赖规则

1. Host 可以依赖 Feature、Platform Contract 和 Adapter；反向依赖禁止。
2. Feature 不能直接依赖另一个 Feature 的 Controller 或实现类型。
3. Feature 对外只暴露稳定的 State、Action/Event、Snapshot 和 Capability Contract。
4. Core 不读取 Keychain、UserDefaults、文件、网络、摄像头、AVAudioSession 或具体供应商 SDK。
5. Adapter 负责供应商字段、鉴权、错误映射和生命周期桥接，不拥有 Feature 业务状态。
6. Renderer 只解释 `HUDScene` 和 `DisplayProfile`，不理解导航、提词或对话业务。
7. 所有跨异步边界事件必须携带 run/session/generation 身份，或由稳定的串行 owner 管理。
8. 新 Package 不是成功指标；优先在现有 Package 内拆 Target，只有存在稳定复用或独立测试边界后再独立成 Package。

## 6. 里程碑总览

```text
M10 基线收口与当前跃迁交付
 ├── M11 提词器可信定位与脚本生命周期
 ├── M12 音频 / ASR 分层与会话高可用
 └── M13 LLM / Search 供应商解耦
          │
          ├── M14 HUD 与 DisplayProfile 视觉可信
          │
          └── M15 Experience 模块化与多 Host 架构
                    │
                    ├── M16 可观测性、CI 与发布可信
                    └── M17 真实眼镜与生产级验收
```

推荐顺序为 M10 → M11 → M12 → M13 → M14 → M15 → M16 → M17。M11 与 M13 在 M10 完成后可以技术上并行，但默认按顺序推进，减少工作树和公共 API 冲突。

## 7. M10：基线收口与 50 字跃迁交付

### 7.1 目标

将当前未提交的 50 字跃迁变化变成可追踪、可复验、可回滚的正式基线，为后续拆模块提供可靠起点。

### 7.2 PR 拆分

#### M10-PR1：当前功能与文档一致性收口

范围：

- 固定当前 50 个规范化字符的定义；
- 确认第 50 个字符属于窗口内，第 51 个字符属于窗口外；
- 确认唯一精确匹配立即跃迁，重复、歧义、不可靠和窗口外匹配保持；
- 核对 `TeleprompterDomain`、Controller、测试、PRD 和复用决策文档一致；
- 不同时加入 checkpoint、撤销、离线 ASR 或长稿索引。

验收：

- Given 当前锚点和窗口内唯一目标，When 单个 ASR partial/final 后缀精确命中，Then 跃迁到对应原文位置；
- Given 第 51 个规范化字符后目标、重复目标或低可信候选，When 事件到达，Then 当前锚点不变；
- 自动跃迁永不后退；
- 手动纠偏后的旧识别事件不能覆盖新锚点；
- 所有受影响 Core/App 测试 0 失败。

#### M10-PR2：锁定工具链与公共 API 复验

范围：

- 在仓库锁定的 Xcode 26.6 / Swift 6.3.3 环境执行 API baseline；
- 复核八个模块、两架构的公开 API 快照；
- 如果存在 API 变化，必须逐项审阅，不自动接受；
- 运行七 Package 严格并发/WAE、App Simulator 和 Release Simulator build。

验收：

- 工具链门禁通过；
- 公共 API 差异为 0，或有单独审阅记录；
- 七 Package 和 App 选择性/全量门禁按 impact plan 通过；
- 不使用旧工具链结果冒充锁定工具链结果。

#### M10-PR3：测试包与真机体验记录

范围：

- 使用内部测试构建验证普通朗读、句内跃迁、跨句跃迁、第 50 字边界、窗口外保持和重复短语保持；
- 单独记录 build、export、install、launch 和功能验收；
- 记录设备、系统版本、App 版本、ASR 配置类型和测试稿件版本，不记录凭证与完整语音内容。

验收：

- IPA 签名、包身份和内部能力扫描通过；
- 设备安装与启动分别有结果；
- 真实普通话跃迁结果有人工记录；
- 失败项进入 M11 离线语料，而不是直接修改阈值掩盖问题。

### 7.3 M10 完成门

- 当前功能已提交/合并需另行获得明确授权；
- 当前工作树无未解释的生成物或秘密；
- 文档、代码、测试和测试包版本一致；
- 真机未通过时可以关闭 M10 的代码基线，但不能宣称设备能力通过。

## 8. M11：提词器可信定位与脚本生命周期

### 8.1 目标

把提词器从“能跟随的 Demo 功能”升级为独立、可评测、可恢复的 Feature。ASR 只提供识别证据，最终位置决策由确定性 Reading Position 领域逻辑负责。

### 8.2 建议状态模型

```text
empty
ready
manual
listening
aligning
degraded(reason)
paused
completed
failed(reason)
```

`degraded` 表示云端或音频不可用但稿件仍可手动操作；`failed` 只用于当前任务无法继续且没有安全降级路径的情况。具体 UI 文案待确认。

### 8.3 PR 拆分

#### M11-PR1：ReadingPositionEngine 契约

在保留现有 `TeleprompterScriptAligner` 兼容入口的前提下，形成纯值定位结果：

```text
stay(reason)
advance(target, confidence, evidence)
jump(target, distance, confidence, evidence)
```

要求：

- Engine 不导入 Combine、SwiftUI、网络、音频或持久化；
- 输入包含脚本版本、当前锚点、转写片段和识别事件语义；
- 输出不得直接修改 Controller；
- reason/evidence 只能是枚举和数值，不包含原始稿件或转写文本；
- 保持当前 50 字行为兼容。

验收：同一输入始终得到相同输出；取消、线程调度和 UI 不影响对齐结果。

实施状态（2026-08-31）：

- 本机代码与自动化验证已完成，行为保持 M10 的 50 字唯一精确跃迁、重复目标保持、partial 稳定后推进和 final 立即推进语义；并发调度下对同一输入得到相同输出。
- public 输入/输出契约已形成，决定对象不包含文本；陈旧脚本版本按 fail-closed 返回保持。
- 兼容入口已保留，Controller 已收敛为会话/生命周期 owner 与决策应用者。
- 因本机工具链低于仓库锁定版本，M11-PR1 只能标记为“本机实现与验证完成”；最终 public API baseline 与正式兼容性审阅待 M10-PR2 锁定工具链补齐。

#### M11-PR2：跃迁稳定、撤销与人工纠偏

已确认范围：

- 保存最近一次自动跃迁的前后锚点和 generation；
- 在手机控制面板提供一次性“撤销刚才的自动跳转”，当前阶段不新增眼镜按键；
- 自动跃迁后进入短暂稳定状态，防止同一批旧 partial 反复改变锚点；
- 人工左/右纠偏优先级高于自动候选；
- 自动逻辑永不回退，撤销属于显式用户操作。

实现规则：

- 只有 Engine 的 `jump` 决策生成撤销记录，普通句内/逐句 `advance` 不生成；
- 记录只含脚本版本、定位代际和跃迁前后数值锚点，不含稿件、转写或供应商 payload；
- 手机按钮仅在当前选中提词器且记录仍可消费时出现；不存在记录时不常驻占位；
- 点击后先一次性消费记录、取消当前识别 Session，再从跃迁前锚点创建新 Session；重复点击为 no-op；
- 人工左/右、下键显式重锚定、脚本替换、reset、shutdown、完成态、后续普通自动推进和不兼容定位代际使旧记录失效；
- 一次话语结束后的兼容 Session rollover 保留撤销资格，但撤销只取消当时的当前 Session，不复活旧 Session；
- 脚本版本、定位代际或当前锚点任一不匹配时 fail-closed。

验收：撤销只恢复最近一次自动跃迁，不能复活已取消 ASR Session；人工纠偏后旧候选全部失效；手机 UI 仅在可撤销状态出现；眼镜四键映射保持不变。

实施状态（2026-08-31）：Core 纯值撤销契约、Controller 消费边界、手机按钮及本机 Package/App/架构/隐私门禁已完成；结果见 3.6 证据快照。真机按钮可用性、真实 ASR 跃迁与物理眼镜体验未验证。

#### M11-PR3：位置 checkpoint 和删除闭环

数据契约建议包含：

- 稳定 script identity；
- 脚本内容版本或不可逆版本标识；
- 当前原文位置与句子位置；
- 写入版本和 schema version；
- 不保存原始 ASR、音频或云端 payload。

触发：暂停、显式完成、App 后台、Experience shutdown、眼镜断连。高频 partial 不直接写磁盘。

恢复规则：

- 脚本版本一致时恢复；
- 脚本内容变化时不能静默套用旧位置；
- checkpoint 损坏时从安全默认位置启动并给出可恢复状态；
- 删除稿件时同时删除稿件、索引、checkpoint 和关联的本地评测缓存。

#### M11-PR4：稿件导入与 ScriptRepository

第一阶段建议支持粘贴、TXT 和 Markdown；DOCX/PDF/云盘留到需求明确后。

边界：

- 文件解析属于 App/Infrastructure；
- `TeleprompterFeature` 只接收规范化的 `TeleprompterScript`；
- 导入失败不覆盖当前可用稿件；
- 超长、空文件、编码异常和重复导入有明确结果；
- 文件名和完整路径不进入遥测。

#### M11-PR5：离线评测集与性能基线

评测集至少覆盖：

- 正常逐字、漏字、多字和少量口头语；
- 句内/跨句 10、30、50、51 个规范化字符跳读；
- 重复短语、重复句和章节标题；
- partial 修订、累计转写、增量转写和跨 Session 续读；
- 静默、噪声占位、同音和中英数字混读；
- 20,000 Character 上限稿件和 30/60 分钟模拟会话。

指标先采集基线，不预设目标值：误跃迁率、漏跃迁率、位置误差、P50/P95 决策耗时、峰值内存和每分钟状态更新数。

### 8.4 M11 完成门

- 提词器领域可在无 App、无网络、无音频条件下独立测试；
- checkpoint 有 schema、迁移、损坏和删除测试；
- 真实 ASR 结果与离线评测结果分开记录；
- 当前 50 字兼容测试继续通过；
- 是否单独建立 `TeleprompterFeature` Target 由稳定公共 API 评审后决定，不以文件行数单独作为拆包依据。

## 9. M12：音频 / ASR 分层与会话高可用

### 9.1 目标

让纯 ASR/VAD 状态机与 Apple 音频采集解耦，并使权限、电话、蓝牙、网络和 recognizer rollover 都进入可观察、可恢复的明确状态。

### 9.2 PR 拆分

#### M12-PR1：ASRDomain Target

机械迁移 provider-neutral 的事件、错误、Session、帧和策略契约；保留兼容导出，禁止同时改变业务行为。

依赖：Foundation、VAD 纯契约；禁止 AVFoundation、具体供应商和 UI。

#### M12-PR2：AudioCaptureApple Target

迁移 AVAudioEngine、AVAudioSession、PCM Converter、系统中断和路由通知。`VoiceChatCore` 只依赖抽象帧源。

要求：

- 音频采集拥有唯一 AudioSession 生命周期 owner；
- start/stop/deactivate 幂等；
- 回调跨线程边界的 `@unchecked Sendable` 必须有同步依据、审计注释和测试；
- 真实路由名称、设备标识和 PCM 不进入默认日志。

#### M12-PR3：ASRSessionSupervisor

建议状态：

```text
idle → preparing → active → finalizing → completed
                   ├→ degraded
                   ├→ recovering
                   └→ failed
```

职责：

- 协调 session rollover、有限重连和旧 Session 拒绝；
- 为每个供应商持有独立恢复状态；
- 只在未发布不可去重内容前重试；
- 恢复失败时返回类型化降级结果，不让 UI 猜测错误；
- 提词器降级到手动模式，对话降级到可重试失败状态。

具体重试次数、超时和退避参数在故障基线后确认。

#### M12-PR4：真实音频故障矩阵

环境包括：

- 内置麦克风；
- 蓝牙 HFP；
- 有线/USB 输入（设备具备时）；
- 电话或其他 App 抢占；
- route change；
- media services reset；
- App active/background；
- Wi-Fi/蜂窝/断网切换。

每项分别记录 capture、VAD、transport、Feature 和 UI 最终状态。

#### M12-PR5：离线 ASR 可行性 Spike

候选可以包含 whisper.cpp 或系统能力，但本 PR 只做可行性和设备测量：模型体积、首次加载、中文准确性、延迟、峰值内存、功耗、温升和最低设备。未通过评审前不进入生产依赖。

### 9.3 M12 完成门

- 替换帧源不修改 ASR/VAD 状态机；
- 音频中断和网络故障有类型化状态及确定性测试；
- 提词器云端不可用时仍能手动完成阅读；
- 真机矩阵有结果，未测试的硬件保持未验证；
- 离线 ASR 未经设备基线不得描述为已支持。

## 10. M13：LLM / Search 供应商解耦与故障隔离

### 10.1 目标

让 LLM Core、Agent、OpenAI-compatible Transport 和博查 Search 成为清晰边界，使替换模型或搜索供应商不修改 Feature、Runtime 和 UI。

### 10.2 PR 拆分

#### M13-PR1：LLMCore 与 AgentCore Target

- `LLMCore`：Message、Tool、StreamingEvent、Transport 和类型化错误；
- `AgentCore`：上下文事务、Tool Round、最大上下文、commit/abort 和终态规则；
- 保留首个 choice、`finish_reason`/`[DONE]`、工具参数完整性和内容发布后不重试等现有不变量。

#### M13-PR2：供应商 Adapter 外移

- OpenAI-compatible HTTP/SSE 实现移到独立 Adapter Target；
- `BochaSearchClient` 与响应模型移到 Bocha Adapter；
- App Composition Root 选择具体 Transport 和 Tool Executor；
- Core 不包含具体 API 地址、鉴权 Header、供应商品牌错误或模型名。

#### M13-PR3：Provider Reliability Policy

为 ASR、LLM 和 Search 分别定义：

- timeout；
- retry eligibility；
- circuit state；
- concurrent operation limit；
- fallback behavior；
- content-safe telemetry events。

不能共享一个全局 Circuit Breaker，避免 Search 故障关闭 LLM 或 ASR。Search 失败是否允许模型继续输出无搜索回答属于产品规则，待确认。

#### M13-PR4：脱敏 record/replay 合约测试

- 保存协议事件结构和时序，不保存真实凭证、用户音频或完整私人文本；
- 覆盖 SSE 分片、乱序工具参数、异常关闭、重复终态、401/429/5xx 和取消；
- replay 必须离线、确定性运行；
- fixture schema 版本化。

### 10.3 M13 完成门

- 替换 ASR、LLM 或 Search Adapter 时不修改 Feature、Runtime、Renderer；
- 每个供应商有独立失败和恢复状态；
- Core 公共 API 快照通过；
- live provider 冒烟测试单独记录，不以 replay 代替真实服务。

## 11. M14：HUD 与 DisplayProfile 视觉可信

### 11.1 目标

从“逻辑计算正确”提升到“在明确设备/Profile 上可重复呈现”，同时继续声明 VST 不能替代真实 OST 光学验证。

### 11.2 PR 拆分

#### M14-PR1：HUDScene schema 与兼容策略

- 给可持久化/传输的 HUDScene 表示增加 schema version；
- 区分领域语义、布局提示和 Host 投影结果；
- 旧 schema 有迁移或明确拒绝策略；
- Feature 不写具体像素坐标。

#### M14-PR2：视觉 Snapshot 测试

覆盖：

- User/Internal 两种构建表现；
- 各内置 Experience；
- 提词器 ready/listening/degraded/paused/completed/error；
- 8:3 默认 Profile 和测试 Profile；
- 不同手机尺寸、动态字体、Reduce Motion、长文本和极端 safe area；
- 三行完整显示和焦点移动。

Snapshot 依赖只进入 Test Target；基线更新必须人工审阅差异。

#### M14-PR3：DisplayProfile Compatibility Matrix

每个 Profile 记录稳定 ID、schema、目标 Host、显示比例、安全区、字体尺度、方向和来源状态。测试 Profile 不得标记为真实硬件标定。

#### M14-PR4：性能与长时渲染

采集 30/60 分钟场景的帧时间、内存、CPU、热状态和状态发布频率。目标阈值在首轮设备基线后确认。

### 11.3 M14 完成门

- HUD 领域值、投影和 SwiftUI 渲染可分别测试；
- 视觉差异有审阅记录；
- 模拟器视觉、手机真机和真实眼镜光学结论分开；
- 不通过缩小字号或压缩字距掩盖信息超载。

## 12. M15：Experience 模块化与多 Host 架构

### 12.1 目标

让新增 Feature 不扩大 App 根组装和 `SingleGreenGlassesKit` 大包，同时为真实眼镜 Host 留出稳定边界。

### 12.2 PR 拆分

#### M15-PR1：Platform Target 拆分

建议先在同一 Package 内形成：

- `HUDDomain`；
- `ExperienceRuntime`；
- `DisplayProfileDomain`；
- `ExperienceTestSupport`。

迁移遵循“先机械移动并保持 API，再单独清理 API”的两步策略。

#### M15-PR2：Feature Target 模板

为复杂 Feature 统一结构：

```text
FeatureState
FeatureAction / DomainEvent
FeatureController or Reducer
FeatureDependencies
HUDMapper
ExperienceAdapter
FeatureTests
```

优先应用于 Teleprompter 和 Conversation；简单静态 Experience 不强制制造无价值抽象。

#### M15-PR3：AppEnvironment 与 FeatureFactory

将 `SingleGreenDemoApp` 的组装拆成不可变环境和 Feature Factory：

- ProviderEnvironment；
- DeviceEnvironment；
- DiagnosticsEnvironment；
- FeatureFactories；
- BuildCapabilities。

禁止全局 Service Locator、运行时任意替换和隐藏单例依赖。

#### M15-PR4：Experience Compatibility Contract

Catalog 元数据提案：

- Experience ID 和 schema version；
- 最低 Runtime contract version；
- 所需 capabilities；
- 无网络/无麦克风/无摄像头时的降级声明；
- 支持的 Host 类型；
- 状态迁移策略。

动态下载代码不在范围内；Catalog 只注册编译期已链接模块。

### 12.3 M15 完成门

- 新增一个示例 Feature 不修改 Runtime、通用 Renderer 和其他 Feature；
- App 根文件不再创建每项供应商细节；
- 架构配置、负向 fixtures 和公共 API 快照覆盖新 Target；
- 单一 Host 仍可独立构建，不被未来 RealGlassesHost 阻塞。

## 13. M16：可观测性、CI 与发布可信

### 13.1 目标

建立“问题可定位、数据不泄露、证据可复现、发布可回滚”的完整工程系统。

### 13.2 PR 拆分

#### M16-PR1：DiagnosticsAPI 与 trace identity

Core 只输出类型化、无内容事件：

- feature/run/session/generation 的临时关联标识；
- phase、outcome、failure code 和 duration；
- jump distance、candidate count、confidence bucket 等不可逆指标；
- 禁止原始转写、稿件、回答、文件名、完整 URL、凭证和设备稳定标识。

具体远程 SDK 不进入 Core；User 构建默认 no-op 或经批准的最小实现。

#### M16-PR2：SLI 基线

先测量再设目标。建议采集：

- crash-free session；
- Feature 任务完成率；
- 提词器误跃迁、漏跃迁、位置误差和决策延迟；
- ASR 首次 partial/final 延迟；
- 中断恢复率和降级后任务完成率；
- LLM 首字、完整回答、Search 成功与失败分布；
- 内存、CPU、热状态和电量变化。

正式阈值、告警和保留周期待隐私及运营方案确认。

#### M16-PR3：CI 可信闭环

- 在 GitHub-hosted runner 验证 impact planner、七 Package、App、Release、coverage 和 public API；
- 保持 fail-closed，未知路径跑全量；
- 保留 exact SHA、Required CI 和内部 pointer equality；
- 上传报告而非 DerivedData/大体积构建树；
- 为 visual snapshot、record/replay 和设备结果建立独立证据分类。

#### M16-PR4：Release Evidence Manifest

每个候选版本记录：

- source SHA、branch、dirty state；
- Xcode/Swift/SDK；
- Package/API baseline；
- 测试和 coverage 报告；
- User/Internal 构建身份；
- archive/export/sign/install/launch 各自状态；
- live provider、手机、真实眼镜和人工验收状态；
- 已知风险、回滚版本和回滚演练结果。

### 13.3 M16 完成门

- 每个发布结论都能定位到 exact SHA 和验证层级；
- User/Internal 产物继续满足隐私与凭证隔离；
- 遥测 schema 有隐私检查和版本兼容；
- Hosted CI 真正运行通过后，才能把本地设计状态升级为 Hosted 证据。

## 14. M17：真实眼镜 Host 与生产级验收

### 14.1 前置条件

- 可用的真实眼镜硬件、SDK/协议和输入定义；
- DisplayProfile/光学参数来源；
- 设备连接、权限和生命周期方案；
- 测试样机和验收场景；
- 生产凭证、服务端短期租约和运营方案。

缺少这些输入时，只能完成 Host Contract 和模拟 Adapter，不能宣称真实眼镜能力。

### 14.2 PR 拆分

#### M17-PR1：RealGlassesHost Contract

定义：

- Renderer Adapter；
- Input Adapter；
- DeviceLifecycle；
- ConnectionState；
- DisplayProfileProvider；
- 可选的 device audio source；
- 诊断和 capability discovery。

#### M17-PR2：真实设备 Adapter

设备 SDK、蓝牙或有线协议只存在于 Infrastructure/Host；Feature 和 Runtime 不导入设备 SDK。

#### M17-PR3：设备与光学验收矩阵

分别验证：

- 连接、断连、重连和固件兼容；
- 按键/触控输入；
- HUD 位置、FOV、畸变、亮度、户外可见性和焦距；
- 提词可读性、误跃迁和人工纠偏；
- 音频路由、延迟和中断恢复；
- 30/60 分钟功耗、温升、内存和稳定性。

#### M17-PR4：生产演练

- 小范围灰度；
- Feature Flag 和配置回滚；
- 服务不可用降级；
- 凭证吊销；
- 版本回滚；
- 诊断采集与隐私复核；
- 故障复盘模板。

### 14.3 M17 完成门

- 真实眼镜 Host 复用既有 Feature，不复制业务状态机；
- 关键任务在目标硬件上有可重复结果；
- 回滚和降级经过演练；
- 生产批准、SLA、合规和客户验收仍需各自授权，不能由代码测试自动推断。

## 15. 高可用设计规范

### 15.1 能力级隔离

| 能力失败 | 必须保持可用 | 建议降级 |
| --- | --- | --- |
| Search | 基础 LLM 会话或明确失败状态 | 不执行需要实时信息的结论，是否允许无搜索回答待确认 |
| LLM | 提词、导航、通知、字幕、本地 HUD | 显示可重试失败，不影响其他 Experience |
| ASR 网络 | 稿件阅读、手动翻页、checkpoint | 提词进入 manual/degraded |
| 麦克风 | 非语音 Experience、稿件手动操作 | 不创建云端 Session，展示权限/设备状态 |
| Camera | HUD 和控制面板 | 显示无相机背景，不影响 Feature 状态 |
| Diagnostics | 业务主流程 | 丢弃诊断或本地有界缓冲，不阻塞 UI |
| 单个 Experience | Runtime 和其他 Experience | 隔离关闭该 Session，不重启整个 App |

### 15.2 恢复规则

- Retry、Timeout、Circuit Breaker、并发限制按供应商实例隔离；
- 已向用户发布不可安全去重的内容后不自动重试；
- 所有重试有上限，可取消，并使用可注入时钟测试；
- 恢复后的新 Session 必须有新 identity，旧 Session 事件继续拒绝；
- 自动恢复不能移动提词锚点、重复提交 Agent context 或复活已结束 Experience；
- 当系统无法判断安全状态时 fail closed，并保留用户可见的手动路径。

## 16. 高可信验证矩阵

| 层级 | 主要证明 | 必须保留的证据 |
| --- | --- | --- |
| Unit | 纯状态和算法确定性 | 测试结果、边界样例、失败样例 |
| Contract | 模块输入输出和兼容性 | Public API、fixture schema、Adapter mapping |
| Integration | 模块真实交换事件 | record/replay、App composition tests |
| Application | 目标 App 构建中的行为 | Simulator XCTest、visual snapshot、构建产物 |
| Device | 指定手机/硬件行为 | 设备/系统/App 版本、步骤和结果 |
| Live Provider | 真实服务行为 | 服务配置类别、时间、成功/失败和脱敏诊断 |
| Real Glasses | 光学、输入、音频与长期体验 | 硬件/固件/Profile、测试矩阵和人工结论 |
| Production | 发布、规模、监控和回滚 | exact SHA、发布清单、SLI、告警和演练记录 |

禁止：

- 用 Unit 测试证明真机；
- 用 build 证明 install/launch；
- 用 iPhone VST 证明 OST 光学；
- 用录制 replay 证明真实供应商可用；
- 用覆盖率证明用户任务正确；
- 用内部 Demo 凭证链路证明生产凭证后端完成。

## 17. 每个 PR 的统一流程

1. 写清目标、行为变化、非目标、模块边界和回滚方式。
2. 先更新或新增失败测试，再做最小实现。
3. 只移动一个 ownership 边界；机械迁移与行为变化分 PR。
4. 运行最窄受影响测试，再运行 reverse dependency 和 App 门禁。
5. 执行 strict concurrency、architecture、public API、privacy、secret 和 diff 检查。
6. 对 public API、依赖图、持久化 schema 或 build capability 变化单独评审。
7. 记录未运行的设备、服务、视觉和生产验证。
8. commit、push、签名安装、设备启动和发布仍需明确授权。

## 18. 统一 Definition of Done

一个里程碑只有同时满足以下项目才可标记为“代码阶段完成”：

- 目标行为和不做项一致；
- 模块依赖方向通过静态和负向 fixture；
- 新状态、失败、取消、边界和恢复均有自动化；
- 公开 API 差异已审阅；
- 受影响覆盖率不低于已批准 gate，具体基线已更新；
- User/Internal Debug 与 Release 的相关产物检查通过；
- 日志、fixture、文档和产物不包含秘密或用户内容；
- 文档记录 exact SHA、工具链和验证层级；
- 所有待完成真机、真实服务、眼镜和生产门禁仍明确列出。

里程碑只有在相应高层证据完成后，才能升级为“设备完成”“真实眼镜完成”或“生产完成”。

## 19. 关键风险与应对

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 一次拆太多 Target | 公共 API、构建配置和测试同时失稳 | 机械迁移与行为修改分开；保留兼容 shim |
| TCA/DI/Telemetry 框架整体迁移 | 大量重写且收益无法证明 | 先借鉴契约；第三方依赖逐项审批 |
| 提词器阈值凭少量真机体验调整 | 对特定稿件过拟合 | 建立离线评测集，记录变更前后指标 |
| 自动重试产生重复内容/上下文 | 用户看到重复回答或上下文污染 | 保持内容发布后不重试、commit/abort 和 generation 规则 |
| checkpoint 与稿件版本错配 | 恢复到错误位置 | script identity/version、schema 和损坏回退 |
| 遥测泄漏语音或稿件 | 隐私与合规风险 | allowlist schema、静态门禁、User no-op 和脱敏审计 |
| VST 结果被外推到 OST | 错误产品决策 | 分开记录手机显示和真实眼镜光学证据 |
| 工具链不一致 | API/并发结果不可比较 | 锁定 Xcode/Swift，并在匹配环境执行发布门禁 |
| Hosted CI 只存在配置未运行 | 误认为远端保护生效 | 完成一次 PR、main 和 promotion 的 Hosted 证据闭环 |

## 20. 实施决策记录

### DEC-M11-001：撤销入口使用手机按钮

| 字段 | 内容 |
| --- | --- |
| 日期 / 里程碑 | 2026-08-31 / M11-PR2 |
| 问题 | 自动跃迁撤销应占用眼镜按键、手机 UI，还是同时提供？ |
| 所选方案 | 仅在手机控制面板提供按钮；当前阶段不改变眼镜四键映射。该方案由用户明确确认。 |
| 理由 | 保留眼镜按键的既有肌肉记忆和映射稳定性，同时为误跃迁提供明确恢复路径。 |
| 备选方案 | 眼镜按键；手机与眼镜同时提供。 |
| 影响范围 | `ControlPanelView`、App 环境注入、Controller 公共可用状态与撤销命令。 |
| 回滚方式 | 移除手机按钮与环境注入；保留 Core 一次性撤销契约可供后续入口复用。 |
| 证据状态 | Core 与 App Simulator 自动化及本机最终门禁已通过；真机触达、按钮尺寸和人工操作体验仍需验证。 |

### DEC-M11-002：撤销记录绑定定位代际，不绑定每次兼容 Session rollover

| 字段 | 内容 |
| --- | --- |
| 日期 / 里程碑 | 2026-08-31 / M11-PR2 |
| 问题 | 一次话语 Session 自动轮换后，最近自动跃迁是否仍可撤销？ |
| 所选方案 | 记录绑定脚本版本、独立定位代际和跃迁目标；相同定位上下文的自动 rollover 保留，重锚定等不兼容上下文失效。 |
| 理由 | 若绑定底层 Session generation，final 后紧随的 rollover 可能让按钮在用户操作前消失；若不做代际约束则可能恢复陈旧位置。 |
| 备选方案 | 每次 Session 变化立即失效；跨所有 Session 永久保留。 |
| 影响范围 | 纯值 `ReadingPositionUndoState`、Controller alignment generation、旧事件拒绝测试。 |
| 回滚方式 | 将 rollover 加入不兼容定位上下文，或收紧/放宽纯值兼容判断；不需迁移持久数据。 |
| 证据状态 | fake Session 已覆盖兼容 rollover、撤销当前 Session 和旧 partial/final 拒绝，相关 Core 全量门禁通过；真实供应商 rollover 尚未验证。 |

### DEC-M11-003：按钮只在可消费时出现

| 字段 | 内容 |
| --- | --- |
| 日期 / 里程碑 | 2026-08-31 / M11-PR2 |
| 问题 | 撤销按钮应常驻禁用还是按需出现？ |
| 所选方案 | 仅在当前选中提词器且存在兼容的一次性记录时出现。 |
| 理由 | 满足“清晰但不过度常驻”，避免长期占用手机控制面板空间。 |
| 备选方案 | 常驻禁用按钮；短时提示条。 |
| 影响范围 | 手机控制面板布局、可访问性标识与 UI 状态策略。 |
| 回滚方式 | 改为常驻禁用或其他可逆呈现，不改变 Core/Controller 契约。 |
| 证据状态 | App Simulator 策略测试及 App 全量 86/86 验证可见条件与集成回归；真机视觉层级与触达性待验证。 |

### DEC-PLATFORM-001：低风险可逆判断采用推荐方案并连续留痕

| 字段 | 内容 |
| --- | --- |
| 日期 / 里程碑 | 2026-08-31 / M10–M17 |
| 问题 | 次要、可逆的产品或架构选择是否每次都暂停等待确认？ |
| 所选方案 | 在不改变核心目标、低风险且可逆时基于 PRD、代码和证据自行选择推荐方案，并在本节记录。 |
| 理由 | 减少实施中断，同时保留审阅、回滚和证据边界。 |
| 备选方案 | 所有选择均逐项等待用户确认。 |
| 影响范围 | M10–M17 后续实施与文档流程。 |
| 回滚方式 | 用户可撤销该授权，后续恢复逐项确认；既有决策仍可按各自回滚方式处理。 |
| 证据状态 | 属流程授权，不构成代码、设备、客户或生产能力证据。账号凭证、费用采购、对外承诺、真实硬件、隐私扩大、破坏性迁移、重大发布策略及设备操作仍必须另行确认。 |

## 21. 待确认事项

以下事项不阻塞 M10 文档与代码基线，但会影响后续行为：

1. Search 失败后是否允许模型在明确声明“未获取实时信息”的情况下继续回答；
2. checkpoint 的保存周期、稿件列表和删除交互；
3. TXT/Markdown 之后是否需要 DOCX、PDF 或云盘导入；
4. 真实眼镜 SDK、协议、硬件参数和样机可用时间；
5. 遥测上传、保留周期、用户同意和运营平台；
6. 离线 ASR 的最低设备、包体和功耗上限；
7. 各项 SLI 的正式目标、告警阈值和验收负责人；
8. 里程碑负责人、开始日期和目标日期，均待确认（责任方未指定）。

## 22. 推荐立即启动的前三个任务

1. 在锁定工具链执行 M10-PR2，并审阅 M11-PR1 新增的 public API：七 Package、App、双架构 public API 和 Release build。
2. 在获准环境补 M11-PR2 真机手机按钮、真实 ASR 跃迁和 rollover 连续性体验。
3. 启动 M11-PR5 离线评测夹具与基线采集，先建立 50/51 字、重复短语、partial 修订和长稿性能证据。

M11-PR1 与 M11-PR2 已完成当前主机可执行的实现与最终门禁。完成锁定工具链 API 审阅后，可继续 checkpoint、导入与 M12 音频/ASR Target 拆分；真机与真实服务仍保持独立验收。

## 23. 参考来源

- [长程平台化路线](./2026-08-28-long-term-roadmap.md)
- [ASR 提词器 PRD](../ASR_TELEPROMPTER_PRD.md)
- [AI / ASR 功能复用决策](../AI_ASR_FEATURE_REUSE_DECISION.md)
- [目标架构](../refactor/TARGET_ARCHITECTURE.md)
- [架构、质量与模块化升级报告](../PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md)
- [CI Workflow](../CI_WORKFLOW.md)
- [Coverage Baseline](../COVERAGE_BASELINE.md)
- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [swift-dependencies](https://github.com/pointfreeco/swift-dependencies)
- [swift-async-algorithms](https://github.com/apple/swift-async-algorithms)
- [LiveKit Swift Client SDK](https://github.com/livekit/client-sdk-swift)
- [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)
- [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
- [Resilience4j](https://github.com/resilience4j/resilience4j)
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
