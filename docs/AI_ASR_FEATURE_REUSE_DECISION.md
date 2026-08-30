# AI 对话、文字冒险与 ASR 提词器架构复用决策

> 状态：已采纳并完成首版 MVP；仍有明确延期项与未验证项
>
> 日期：2026-08-30
>
> 范围：`SingleGreenGlassesKit`、`SingleGreenConversationAdapters`、`LLMKit` 与 App 组合层
>
> 结论摘要：复用稳定的设备无关契约、HUD 排版与事件基础设施；不复用具有不同会话语义的 Controller。ASR 提词器不调用 LLM，也不把识别文本当作生成内容。

## 1. 背景与问题

当前产品同时涉及三类体验：

1. **AI Conversation**：用户说话，Agent 生成回答；需要上下文事务、流式回复、工具调用与取消隔离。
2. **Text Adventure**：用户用四向键选择，DeepSeek 在游戏规则内生成故事节点；需要确定性的游戏状态、结构化输出校验与存档。
3. **ASR Teleprompter**：用户先导入固定讲稿，ASR 只用于判断“讲到哪里”；需要持续识别、局部对齐、静默保持与人工纠偏，不生成或改写讲稿。

三者都可能使用 ASR、网络传输、HUD 文本和四向键，但“谁拥有真相”和失败语义完全不同。若仅因表面相似而共享 Controller，会把对话事务、游戏推进和脚本位置跟踪混在一起，增加错误跳转、陈旧事件污染和隐私风险。

本决策回答：哪些能力应当复用，哪些状态必须隔离，以及 ASR 提词器应当落在哪一层。

## 2. 决策

### 2.1 总体原则

- 复用**稳定、语义中立的能力**：ASR 事件契约、音频采集适配、HUD 测量、`Character` 安全切分、Experience 注册与通用控制动作。
- 隔离**产品状态机和完成条件**：AI 对话、文字冒险、提词器各自拥有 Controller、Domain State 和取消代际。
- `SingleGreenGlassesKit` 只持有设备无关行为和端口，不导入 SwiftUI、UIKit、AVFoundation、供应商 SDK、凭据或设置存储。
- App/Live Adapter 层持有供应商能力、权限、凭据、网络、音频路由和具体配置。
- LLM 只服务“生成/推理”的体验。提词器的脚本位置必须由确定性的文本对齐器决定，禁止通过 DeepSeek/LLM 猜测当前位置。

### 2.2 依赖方向

```text
SingleGreenDemo composition root
  ├─ AI Conversation
  │   └─ VoiceConversationController
  │       ├─ Conversation ASR/Agent ports
  │       └─ SingleGreenConversationAdapters
  │           ├─ VoiceChatCore
  │           └─ LLMKit（流式、工具轮次、上下文事务）
  │
  ├─ Text Adventure
  │   └─ TextAdventureController + TextAdventure domain
  │       └─ TextAdventure port
  │           └─ App live adapter
  │               └─ LLMKit transport + bounded stateless tool loop
  │
  └─ ASR Teleprompter
      └─ TeleprompterController + Teleprompter domain
          ├─ SpeechRecognitionSession（MVP：一次话语后自动轮换）
          ├─ deterministic ScriptAligner
          └─ App live adapter
              └─ VoiceChatCore / provider ASR（按能力适配）

Deferred evolution
  └─ dedicated continuous teleprompter recognition port

Shared presentation primitives
  ├─ DisplayProfile（8:3 可见安全区）
  ├─ measured complete-line viewport
  ├─ grapheme-safe text boundaries
  └─ ExperienceRuntime + generic four-action routing
```

任何箭头都不能反向：视图不得修改业务状态，供应商实现不得进入 Core，提词器不得依赖对话或游戏 Controller。

### 2.3 当前实现快照

截至 2026-08-30，首版 MVP 已按上述边界落地：

- `SingleGreenGlassesKit` 已拥有独立的 Teleprompter Domain、确定性前向对齐器、Controller、HUD Mapper 与 Experience；
- App 持有脚本草稿和云端 ASR 同意设置；云端同意持久化且默认拒绝；
- Live Composition 只接收 speech-scoped credential provider，提词器拿不到 DeepSeek/搜索等其他能力的凭据；
- 后台与 shutdown 会立即使当前 generation 失效、取消事件消费并发起 session cancellation；
- 当前供应商仍是一次话语 Session，Controller 在 `.finished` 后自动创建下一次 Session；自动化已覆盖旧 Session 事件隔离，但真实服务与真机上的连续性尚未验证；
- 控制面板通过通用 Experience actions 操作体验，没有读取具体 Teleprompter Controller；脚本编辑和同意开关属于 App 自有设置；
- HUD 已用 TextKit 的真实 line fragment 测量，只选择完整行，并以结构化 UTF-16 段落偏移居中选择 3 行；高度不足时自然退化为 2 条完整行；
- 当前只支持手机端粘贴/编辑并载入稿件和四键短按；TXT 文件导入、长按段落跳转/结束/模式切换尚未实现。
- 为保留既有调用方，后续补入了 retained public initializer 的 compatibility overloads；补丁后 LLM stateless 与 Teleprompter 聚焦套件重新执行并通过。

## 3. 能力复用矩阵

| 能力 | AI Conversation | Text Adventure | ASR Teleprompter | 决策 |
|---|---|---|---|---|
| Experience 注册、选择与通用动作 | 复用 | 复用 | 复用 | 保持通用 `ExperienceControlState`，模拟器不读取具体 Controller |
| 8:3 `DisplayProfile` 与安全区 | 复用 | 复用 | 复用 | 所有体验共享显示边界，但页面预算由各体验定义 |
| 完整行、字素安全排版 | 复用 | 复用 | 复用并强化 | 提词器必须只显示完整行，不使用省略号或半行裁切 |
| ASR 音频采集/供应商适配 | 复用适配层 | 当前非必要 | 复用底层能力 | 共享 transport/capture，不共享会话结束语义 |
| `SpeechRecognitionSession` | AI 对话经适配使用 | 不使用 | MVP 直接复用并自动轮换 | Core 自动化覆盖轮换/旧事件隔离；真实连续性未验证，必要时再演进专用连续端口 |
| `VoiceConversationController` | 使用 | 禁止 | 禁止 | 上下文、回复生命周期和完成条件不同 |
| `TextAdventureController` | 禁止 | 使用 | 禁止 | 游戏节点推进不等于脚本锚点推进 |
| LLMKit 流式对话/上下文事务 | 使用 | 不使用会话上下文 | 禁止 | 提词器必须可解释、可复现、离线降级 |
| LLMKit transport | 经 Agent 使用 | 用于结构化故事节点 | 禁止 | 提词器的讲稿是用户提供的唯一文本真相 |
| 有界无状态工具循环 | 不作为主会话 | 用于开局准备/趋势检索 | 禁止 | 只服务文字冒险的运行简报，不成为通用业务状态机 |
| 本地 checkpoint | 对话上下文另管 | 游戏存档 | 目标保存脚本位置；MVP 未实现 | 三者数据模型和清理策略分开，不能把脚本草稿持久化误称为位置 checkpoint |

## 4. 各体验的状态所有权

### 4.1 AI Conversation

`VoiceConversationController` 继续拥有：

- 一轮输入、识别、生成、逐字显示和取消状态；
- reply identity 与 generation 隔离；
- 最终成功后才提交 Agent 上下文；
- 失败、取消、重置和陈旧事件不提交上下文。

LLMKit 继续拥有供应商中立的聊天、SSE、工具调用组装和上下文事务，不承载眼镜 HUD 或产品状态。

### 4.2 Text Adventure

`TextAdventureController` 独立拥有：

- 运行 seed、世界简报、节点、选项、资源和 checkpoint；
- 每次四向选择对应的单一推进事务；
- 节点生成任务、代际检查、取消与 HUD 逐字状态；
- 结构化输出验证失败时的显式恢复，而不是静默污染游戏状态。

DeepSeek 负责受规则约束的叙事生成，不是游戏状态真相。游戏 Domain 保存最小、可验证的状态；供应商响应必须先通过 schema 与业务规则校验，再进入状态机。

### 4.3 ASR Teleprompter

已新增独立的 `TeleprompterController`，其唯一真相是：

```text
ImportedScript
  -> normalized matching tokens
  -> original-text ranges
  -> sentence / paragraph / measured-line index
  -> confirmed anchor
```

Controller 拥有：

- 脚本准备、当前确认锚点、候选锚点、识别代际和模式；
- transcript/utterance 的 generation 隔离、重复 partial 计数和前向确认；显式供应商 sequence/stability 尚未引入；
- 即兴/歧义保持、人工纠偏与重捕获；显式静默计时和跨段跳读规则尚未引入；
- 暂停、恢复和会话清理；位置 checkpoint 与显式完成态仍属延期；
- HUD 页面模型，不持有 SwiftUI 测量实现。

`ScriptAligner` 是纯确定性组件：相同脚本、锚点、事件序列和参数必须得到相同结果。它不得联网、读取设置、调用 LLM 或直接写 UI。当前 MVP 已实现有界向前、歧义保持的子集；显式静默状态、完整 token/range 索引和跨段落稳定规则仍属增强项。

## 5. 提词器识别端口：目标与当前实现

对话 ASR Session 以“一次发言完成”为中心，可能在静默或手动结束后终结。首版 MVP 为控制改动范围，实际复用了供应商中立的 `SpeechRecognitionSession`，并在 `.finished` 后自动轮换到新 Session；失败则保留锚点并降级手动。

该实现已通过 fake session 自动化验证：轮换不会自等待死锁，旧 Session 的迟到事件不会污染新 generation。但以下结论仍不能从自动化推出：真实云端是否存在可感知空窗、供应商最长会话限制、网络切换、眼镜长时使用的连续性。它们必须由 live provider 和物理设备验证。

下面的连续识别端口仍是后续演进建议，不是当前已实现 API：

建议在 Core 定义供应商中立的连续识别端口，名称仅为示意：

```swift
public enum TeleprompterRecognitionEvent: Sendable, Equatable {
    case partial(sequence: UInt64, text: String, stability: Double?)
    case final(sequence: UInt64, text: String)
    case audioLevel(Float)
    case availabilityChanged(Bool)
    case failed(TeleprompterRecognitionFailure)
}

public protocol TeleprompterRecognitionSession: Sendable {
    var events: AsyncThrowingStream<TeleprompterRecognitionEvent, Error> { get }
    func start() async throws
    func pause() async
    func resume() async throws
    func finish() async
    func cancel() async
}
```

约束：

- `sequence` 必须单调，过期代际、重复序列和取消后的事件一律忽略。
- audio level 只用于状态提示，绝不是位置推进证据。
- `pause()` 必须停止采集或上传，而非只冻结 UI。
- Core 错误为产品语义（权限、不可用、中断、网络、超时），不得泄露供应商类型。
- Live Adapter 可将供应商的连续流、内部 session rollover 和网络重连映射到该端口。

## 6. HUD 与控制复用决策

### 6.1 HUD

复用当前 8:3 `DisplayProfile`、可见安全区和基于真实字体测量的排版能力；为提词器补齐通用的“完整行视口”能力，而不是在业务字符串上硬截取。

提词器页面规则：

- 只呈现 3 条完整正文行，当前行位于中间；
- 不缩小到低于可读字号、不显示省略号、不裁切半个汉字或半行；
- 所有索引按 Swift `Character`/原文 range 映射，规范化文本只用于匹配；
- 页面移动按完整行吸附，Reduce Motion 下立即切换，无逐字动画；
- SwiftUI 只测量和渲染，由 Controller 提供可测试的行/状态模型。

### 6.2 四向键

复用 Experience 的四动作路由，不复用某个具体体验的动作实现。当前 MVP 已实现四键短按；长按仍是目标设计：

| 按键 | 短按（已实现） | 长按（延期） |
|---|---|---|
| 左 | 上一句 | 上一段 |
| 右 | 下一句 | 下一段 |
| 上 | 暂停/继续 | 结束本次提词 |
| 下 | 跟随中重新锚定；非跟随态切换 ASR/手动 | 预留，不在当前 MVP |

当前动作经通用 `ExperienceControlState` 路由，并用 generation 隔离异步结果。长按加入时仍需补齐去抖、一次按压一次提交和长短按互斥测试。

## 7. 备选方案与否决理由

| 方案 | 结论 | 理由 |
|---|---|---|
| 在 `VoiceConversationController` 增加 teleprompter mode | 否决 | 一次发言/回复事务与长时脚本跟随的完成、暂停、静默语义冲突 |
| 复用 `TextAdventureController` 的四键状态机 | 否决 | 四键只是输入外形；游戏节点生成和脚本锚点没有共同 Domain |
| 让 DeepSeek 根据 ASR 推测讲到哪里 | 否决 | 不确定、不可复现、增加延迟与成本，且可能改写/泄露讲稿 |
| 直接在 SwiftUI 中搜索 ASR 字符串 | 否决 | 视图会拥有业务状态，无法确定性测试，重复句与 partial 修订会误跳 |
| 继续使用一次话语 ASR Session 并在结束后重启 | MVP 已采用，附带验证缺口 | 自动轮换与陈旧事件隔离已实现；真实服务/真机是否存在句间空窗仍未验证，验证不通过时升级为连续端口 |
| MVP 立即抽取新 Package | 暂缓 | 先在既有边界验证契约；出现第二个复用方或独立发布需求后再抽取 |

## 8. 分阶段落地顺序

1. **已完成**：在 `SingleGreenGlassesKit` 定义 Teleprompter Domain、纯 `ScriptAligner`、Controller、HUD Mapper 与 fake-session 测试。
2. **已完成（MVP 形态）**：在 App 组合层接入 speech-scoped credential 和一次话语 ASR Session；权限、凭据和云端同意不进入 Core。
3. **已完成**：在 HUD 层用 TextKit 测量完整行，焦点居中最多取 3 行，高度不足时取 2 行。
4. **已完成**：通过 Experience descriptor 注册提词器并接入四向短按；控制面板不读取具体 Controller。
5. **最终 checkout 自动化与编译已完成**：SingleGreenGlassesKit 222/222、App Simulator 87/87、Debug/Release generic iphoneos build 和全部列出的架构/安全/发布门禁均通过。live provider 调用和物理设备 install/launch 仍待执行。
6. **延期**：TXT 文件导入、长按动作、连续 ASR 专用端口、checkpoint/删除闭环和独立 `TeleprompterKit` Package。

## 9. 主要风险与控制

| 风险 | 控制 |
|---|---|
| partial ASR 反复修订造成页面来回跳 | 只前进确认锚点；候选需稳定证据；ASR 不得自动后退 |
| 中文重复短语匹配到错误位置 | 局部窗口、信息量阈值、邻近单调优先；歧义时冻结等待人工纠偏 |
| 静默或即兴插话导致错误推进 | 静默/低置信度只进入保持态，不视为完成，不消费脚本 |
| 供应商单次识别时长限制 | MVP 已实现一次话语结束后的自动轮换与旧事件隔离；“无缝”仍需 live provider/真机证据 |
| HUD 半行或半字裁切 | 真实字体测量、完整行分页、`Character` 边界与像素级快照测试 |
| 云端隐私 | 明示模式、暂停即停采集、默认不保存音频/转写、只记录聚合遥测 |
| 与现有体验产生回归 | 独立 Controller/ports；保持依赖方向；先跑窄测试再跑相关全量门禁 |

## 10. 验证状态（2026-08-30）

本节区分自动化实现证据、构建证据和仍未执行的真实环境验证。测试计数来自父任务提供的本轮结果；本文没有重新运行产品测试。

| 证据类别 | 当前状态 | 可以说明什么 | 不能说明什么 |
|---|---|---|---|
| 文档静态检查 | 已通过：逐文件 whitespace check 与敏感信息模式扫描 | 两份 Markdown 未发现 diff 空白错误或常见密钥模式 | 不验证产品逻辑或运行时行为 |
| 最终 Core 自动化 | 已通过：SingleGreenGlassesKit 222/222 | 最终 checkout 的 Core 提词器、体验与相关回归测试通过 | 不代表真实 DeepSeek、搜索或 ASR 服务可用 |
| 最终 App Simulator 全量 | 已通过：87/87，0 failures，0 skips；iPhone 17 Pro，iOS 26.5；证据：`/private/tmp/SingleGreenDemo-ControlPanelFullTests/Logs/Test/Test-SingleGreenDemo-2026.08.30_10-05-03-+0800.xcresult` | 最终 checkout 的 App test target 全量通过 | 不等于 live provider 或物理设备验证 |
| generic iphoneos 编译 | Debug exit 0；Release exit 0 | 最终 checkout 可为 generic iphoneos 编译两种配置 | generic build 不等于在具体设备 install/launch |
| 发布与隐私门禁 | 已通过：Release credential isolation、repository hygiene、privacy logging、VAD privacy、secret scan、architecture gates、final public API baseline check | 最终 checkout 满足已执行的凭据隔离、仓库卫生、隐私与 API 基线静态门禁 | 静态门禁不替代真实服务或设备行为验证 |
| Live provider | 未运行 | 无 | 不能宣称真实 DeepSeek、搜索或 ASR 的准确率、延迟与轮换连续性 |
| 物理设备 install/launch | 未运行 | generic iphoneos Debug/Release build 已通过 | 不能宣称安装、启动、眼镜可读性、按键或音频路由通过 |

最终 checkout 的 Core、App Simulator 全量、Debug/Release generic iphoneos 编译和列出的发布门禁已经补齐。剩余证据缺口是 live DeepSeek/搜索/ASR 调用，以及物理设备 install/launch 和人工可读性/音频路由验证。
