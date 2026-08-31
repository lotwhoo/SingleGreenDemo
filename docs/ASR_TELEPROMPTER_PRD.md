# 单绿眼镜 ASR 智能提词器 PRD

> 版本：MVP Implemented Baseline v1.8（含 M11-PR1–PR4 第一阶段与延期/未验证项）
>
> 日期：2026-09-01
>
> 产品定义：用户导入/粘贴讲稿，ASR 只跟踪已说到的位置；系统不生成、不续写、不改写讲稿。
>
> 目标硬件：单绿色单目 HUD，8:3 可见区域，四向按键。

## 1. 结论摘要

首版 MVP 已实现为“**语音跟随、三完整行、随时可手动接管**”的提词器，没有把 AI 对话或 LLM 生成塞进提词流程。

核心循环：

```text
手机端粘贴或导入 UTF-8 TXT/Markdown 并载入讲稿
  -> 删除空格与 Tab、把连续换行折叠为一个 `/`，再做本地规范化和测量分页
  -> 启动语音跟随（一次话语 Session 自动轮换）
  -> 在当前已读位置后的 50 个规范化字符内匹配已说内容
  -> partial 驱动句内完整行上移，当前句证据稳定后推进到下一句
  -> 静默/插话/歧义时保持
  -> 自动跃迁后可在手机端一次性撤销
  -> 四向键纠偏、暂停或切换纯手动
  -> 暂停/完成/后台/shutdown 保存兼容位置；手机确认后完整删除本地稿件与派生数据
```

成功标准不是“ASR 转写看起来准确”，而是演讲者抬眼时，当前要说的内容稳定地处于中间行，且系统绝不因识别猜测自动向后跳。向后恢复只允许由用户明确点击手机端的一次性撤销，或使用既有人工纠偏。

当前证据边界：本次 checkout 的 SingleGreenGlassesKit 265/265、SingleGreenUser App Simulator 93/93、七 Package strict-concurrency/WAE 561/561、User Release Simulator build、架构边界和敏感信息扫描已通过；checkpoint 聚焦 4/4、提词器聚焦 47/47。Xcode 26.6 public API baseline 与真机检查按用户决定延期至 2026-09-02，本轮未尝试。真实 DeepSeek/搜索/ASR 调用、位置恢复/导入/删除的物理设备复验和长时可读性仍未验证。

## 2. 用户与待完成任务

### 2.1 目标用户

| 优先级 | 用户 | 核心任务 | 典型时长 |
|---|---|---|---|
| P0 | 产品经理、销售、创业者 | 在路演、产品演示、客户沟通时保持话术完整，同时维持眼神交流 | 3–15 分钟 |
| P0 | 教师、培训师、主持人 | 按既定结构讲述，临时停顿或发挥后能回到稿件 | 10–45 分钟 |
| P1 | 单人视频创作者 | 看镜头录制，不用手动控制固定滚速 | 1–20 分钟 |
| P1 | 需要记忆辅助的演讲者 | 忘词时快速找回当前位置，不暴露完整稿件给观众 | 3–30 分钟 |

### 2.2 非目标场景

- 驾驶、骑行、步行穿越道路等安全关键场景；
- 实时字幕、会议转写、翻译或自由问答；
- 多说话人自动区分；
- 隐蔽录音或未经同意的第三方语音采集；
- 用 LLM 续写、改写、总结或替换用户讲稿。

## 3. 竞品与一手资料

以下是截至 2026-08-30 查阅的官方/一手资料。产品事实与本 PRD 的推荐严格分开。

### 3.1 已确认的竞品事实

| 产品/资料 | 官方公开能力 | 对本产品的启示 |
|---|---|---|
| [PromptSmart VoiceTrack 帮助](https://promptsmart.com/support/help) | 官方描述 VoiceTrack 会随说话滚动，暂停或即兴发挥时停止，并在回到稿件后继续 | “静默/插话保持、回稿恢复”是语音跟随的核心承诺 |
| [PromptSmart 隐私政策](https://my.promptsmart.com/privacy-policy) | 官方说明 VoiceTrack 的语音识别在设备端执行；脚本默认保存在本地，用户启用同步时除外 | 本地优先、明确同步边界可成为信任优势 |
| [Teleprompter.com VoiceGlide](https://www.teleprompter.com/features/voice-scrolling) | VoiceGlide 按声音推进，并强调暂停/继续和设备端处理 | 固定滚速不应是唯一模式；隐私说明应在开始前可见 |
| [Teleprompter.com Script Import](https://www.teleprompter.com/features/script-import) | 支持多种脚本来源与文件格式 | MVP 可先聚焦粘贴/TXT，后续再扩展 DOCX/PDF/云盘 |
| [Even G2 Teleprompt](https://support.evenrealities.com/hc/en-us/articles/14273863878415-Teleprompt) | 官方支持 TXT/DOCX/PDF、手动/自动/AI 模式、已读文本变灰、语音跟随与人工纠偏；并说明不同手机平台的离线/在线差异 | 智能跟随必须保留物理键纠偏；眼镜端无需显示识别原文 |
| [BIGVU Mobile Teleprompter](https://bigvu.tv/tools/teleprompter-mobile-teleprompter-ios-android/) | 官方页面展示可调滚速、暂停/继续和移动端录制式提词方案 | 固定速率/远程控制可作为降级或后续能力，不应阻塞 MVP |
| [Vuzix UX Design Guidelines](https://support.vuzix.com/docs/ux-design-guidelines-1) | 智能眼镜设计指南强调界面简洁、信息可快速读取 | 单目 HUD 应限制层级、状态文案和同时可见内容 |
| [AR 文本可读性研究](https://pubmed.ncbi.nlm.nih.gov/41265010/) | 研究摘要指出更小字号和更紧字距会降低 AR 文本可读性 | 不能为塞入更多字而持续缩小字号或压缩字距 |
| [Apple Speech 文档](https://developer.apple.com/documentation/speech) | 提供语音识别框架；设备端支持和语言/设备能力需运行时判断 | 本地识别是能力分支，不应假定所有设备与语言都可用 |
| [Apple `supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition) 与 [`requiresOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition) | 官方提供查询支持度和要求设备端识别的 API | 开始前必须 capability check；不支持时明确转云端或纯手动 |
| [Apple WWDC23：Customize on-device speech recognition](https://developer.apple.com/videos/play/wwdc2023/10101/) | 官方介绍通过自定义语言模型改善特定词汇识别 | 产品名、专有名词词表属于后续准确率优化，不进入 MVP 核心链路 |
| [EvenDemoApp Text Sending](https://github.com/even-realities/EvenDemoApp#text-sending) | 官方示例仓库公开眼镜文本发送能力 | 端到端实现需把排版页与传输协议分离，避免业务层依赖设备 SDK |

### 3.2 产品推荐（非竞品事实）

- 首版优先“稳定位置”而非“实时逐词炫技”：只在证据稳定后按完整行推进。
- 智能跟随不是唯一逃生通道：任何时刻都能用四向键纠偏或切换纯手动。
- 不在眼镜上展示 ASR 转写；只显示用户原稿，避免识别错字污染提词内容。
- 不以“AI”作为必要卖点。确定性对齐更低延迟、可离线降级、可测试且更保护隐私。

## 4. 场景优先级

| 场景 | 优先级 | MVP 行为 |
|---|---|---|
| 讲稿预演 | P0 | 已实现粘贴/编辑、UTF-8 TXT/Markdown 导入、载入、ASR 跟随、暂停/继续、手动纠偏和位置恢复 |
| 现场演讲/演示 | P0 | 三完整行、低打扰状态、静默保持、断网转纯手动 |
| 忘词/跳段恢复 | P0 | 已实现上/下一句和当前句重新锚定；上一段/下一段依赖长按，延期 |
| 即兴插话后回稿 | P0 | 不消费稿件；识别到局部窗口内稳定证据后继续 |
| 单人视频录制 | P1 | 同一跟随能力；相机录制不属于本模块范围 |
| 全离线使用 | P1 | 当前只有纯手动模式；设备端 ASR 属于 Later，不阻塞讲稿显示 |
| DOCX/PDF/OCR、云盘 | Later | 文件解析、版式清洗和同步 |
| 远程导播、多语言、排练分析 | Later | 在核心指标稳定后评估 |

## 5. 端到端流程

### 5.1 手机端准备

1. 用户进入“ASR 提词器”，可在 App 内粘贴/编辑，或从手机文件选择器导入 UTF-8 TXT/Markdown；导入成功后自动载入。空白、非法 UTF-8、超过 20,000 字、不支持类型和重复内容均返回明确结果，失败不覆盖当前稿件。
2. 系统保留原始稿件副本；载入显示稿时删除空格、Tab 等布局空白，连续 CR/LF 折叠为一个 `/`，开头和结尾的换行不生成 `/`，不生成空句或空白显示行。该规则也会删除英文单词之间的空格，这是当前产品明确选择。
3. 当前系统建立句子序列和确定性脚本版本标识，并由纯值 `ReadingPositionEngine` 用规范化文本做有界前向匹配；版本标识只用于拒绝陈旧事件，不是加密摘要。完整 token/range/段落索引仍是后续增强。
4. 当前由首句或已在运行中选择的句子开始，查看 8:3 眼镜预览；手机端段落选择尚未实现。
5. 当前云端 ASR 同意由 App 持久化且默认拒绝。用户明确开启后才请求麦克风并准备 speech-scoped session；设备端 ASR capability 分支尚未实现。
6. 用户主动开始，才启动音频采集。

### 5.2 眼镜端使用

1. Ready 页面显示第一句和操作提示。
2. 短按上键开始/暂停；当前实现以 `preparing`/`listening` 表示准备与跟随，没有独立暴露 `SEARCHING`。
3. 对齐器只在当前确认位置向前 50 个规范化字符内搜索；若用户突然朗读窗口内后文，唯一精确命中会立即跃迁到对应位置。重复短语、窗口外内容或不可靠匹配仍保持不动。
4. partial 转写推进当前句内位置；焦点跨过完整显示行时，以 0.18 秒向上过渡并继续露出未读内容。三行依次为已读、正在读、未读：已读内容为 32% 深绿、当前行为 100% 高亮、未读行为 68% 中绿。正文不自动添加箭头或完成符号，分段只显示规范化后的单个 `/`；首尾不插入空白占位。
5. 静默、即兴插话或低置信度时冻结页面，不自动完成。
6. 用户可随时左右纠偏，或下键重新锚定/切换纯手动。
7. 暂停、自动到稿尾、Controller 显式完成、App 后台和宿主 shutdown 会保存版本兼容的位置 checkpoint；普通 ASR partial/final 位置变化与 reset 不直接写盘。显式完成的手机/眼镜手势尚未接入，App 未持久化音频或识别全文。
8. 若系统刚执行一次 `jump` 自动跃迁，手机控制面板临时出现“撤销刚才的自动跳转”；点击一次恢复跃迁前锚点并重建识别 Session，随后按钮消失。眼镜按键映射不变。
9. 手机端可经二次确认删除稿件；删除会以单一版本化本地记录替换同时清除稿件、checkpoint、预留索引和本地评测缓存，且旧 Session 事件不能恢复已删除状态。

### 5.3 脚本预处理与双文本模型

目标模型仍应同时维护：

- `displayText`：用户原稿，供 HUD 显示，字符和标点不得被 ASR 改写；
- `matchTokens`：仅用于匹配的规范化序列，例如大小写、Unicode、空白、口语填充词、数字读法和中英文标点归一。

当前 MVP 保留脚本原文和分句文本，并在匹配时临时规范化；尚未建立完整的 token-to-original range/paragraph/measured-line 持久索引。HUD 已通过 TextKit line fragments 和 `Range(..., in: text)` 在原文上选择完整行，避免破坏组合字素。

## 6. 四向键映射

| 按键 | 短按 | 长按 | 当前状态 |
|---|---|---|---|
| 左 | 上一句，并将其设为锚点 | 上一段 | 短按已实现；长按延期 |
| 右 | 下一句，并将其设为锚点 | 下一段 | 短按已实现且末尾不越界；长按延期 |
| 上 | 开始、暂停或继续 | 结束本次提词 | 短按已实现；长按延期 |
| 下 | 跟随中从当前句重启识别；Ready/Paused 切到手动；Manual 重试 ASR | 预留 | 短按已实现；长按未定义/未实现 |

手机端补充控制：

- “撤销刚才的自动跳转”不占用眼镜按键，只在存在可消费记录时出现；
- 只撤销最近一次 Engine `jump`，普通 `advance` 不生成撤销记录；
- 点击后先消费记录并取消当前 Session，再从旧锚点建立新 Session，重复点击不生效；
- 人工左/右、下键重锚定、脚本替换、reset、shutdown、完成态、后续普通自动推进和不兼容定位代际使按钮失效。

交互约束：

- 当前只接入短按。加入长按时，长按触发后不得再触发短按，并需补齐去抖和一次物理动作最多一次提交。
- 当前 `preparing` 再次短按会暂停/取消；“启动中重复开始仍保持启动且不创建第二个 session”是目标行为，尚未单独验证。
- 手动跳转立即生效，并递增 alignment generation；旧 ASR 候选不得覆盖新锚点。
- 到达首句/末句时保持原位，给出短促边界提示，不循环跳转。

## 7. HUD 信息与字符预算

### 7.1 固定布局

```text
┌────────────────────────────────────────┐
│ 设备端 · 42%                            │  状态/进度
│      上一完整行（35–45% 亮度）          │
│      当前完整行（100% 亮度）            │
│      下一完整行（70–80% 亮度）          │
└────────────────────────────────────────┘
```

### 7.2 预算与排版规则

| 区域 | 预算 | 规则 |
|---|---:|---|
| 正文 | 固定 3 条完整测量行 | 每行实际字数以设备字体测量为准 |
| 顶部状态 | 单行 | 合并进度、模式和当前可执行动作；网络错误优先 |
| 字号 | 14 pt | 单绿 HUD 的题词正文专用字号；物理眼镜可读性待验证 |
| 换页 | 完整行吸附 | 禁止连续像素滚动、半行、半字、尾部省略号 |

进一步约束：

- 可见行数由真实字体、行距和安全高度计算，不能用“字符数/常数”代替测量。
- 所有受支持的显示配置必须为 3 条完整正文行预留安全高度；不得在受支持配置中降为 2 行。新增显示配置上线前必须通过三行高度测试。
- 状态颜色在单绿色 HUD 上不能作为唯一信息，必须配合文字/图标或亮度层级。
- `Reduce Motion` 开启时直接切换到新页面，不做逐字或滑动动画。
- 眼镜端永远显示原稿，不显示 ASR 的 partial/final 转写。

当前实现状态：TextKit 使用与 HUD 一致的字体度量枚举完整 line fragments；提词器通过结构化 `isFocused` 文本片段传递句内位置，不依赖正文中的箭头、完成符号或空行。空格与 Tab 被删除，连续换行折叠为一个 `/`，ASR 匹配时忽略该分段符。三行窗口把焦点上一完整行固定为 32% 深绿已读、焦点行固定为 100% 高亮正在读、焦点下一完整行固定为 68% 中绿未读；开头和结尾使用“尚未朗读”“已到稿尾/已读完”补足语义行。状态与进度合并到顶部，正文使用独立的 14pt 字体和 80% 安全区高度，确保默认 iPhone 17 Pro Max 的 8:3 预览容纳 3 条完整行。焦点跨行后旧窗口向上退出、新窗口从下方进入；Reduce Motion 下直接刷新。App/HUD 自动化覆盖三档绿色、三行语义、默认真机投影尺寸、完整 Unicode 行片段、句内焦点选择和向上过渡时长；物理眼镜上的最终字号、疲劳和安全区仍未验证。

## 8. ASR 位置跟踪算法

### 8.1 局部、单调、稳定

1. 以 `confirmedAnchor` 为中心建立有界局部窗口，优先向前，保留少量回看上下文。
2. 用 token 加权编辑距离/LCS 或等价的确定性评分生成候选；中文可采用字/短词混合 token。
3. partial 只更新候选；满足稳定门槛才提交确认锚点。初始启发值为“至少 3 个有信息量 token 或 6 个中文字符”，最终阈值由离线语料评估决定。
4. 多个重复短语同分时选择距离最近且单调向前的候选；仍歧义则进入 `UNCERTAIN`，不得猜测跳转。
5. ASR 自动推进可以保持或向前，绝不自动向后；向后只能由用户操作。
6. 识别到明显跳读时，若目标起点位于当前已读位置后 50 个规范化字符内，且 ASR 后缀在窗口内唯一精确命中，则单个事件立即跃迁；非精确候选仍须至少两个连续事件支持同一位置才允许推进。
7. partial 被后续修订时，只撤销未确认候选，不回滚已确认页面。

本次实现假设：“50 个字”按匹配用的规范化字符计数，只计算字母、数字和 CJK 字符；空格、标点、换行、段落标记、emoji 和其他符号不占额度。候选起点为第 50 个字符时仍属于窗口内。若后续需要按原稿可见字符计数，应作为独立规则调整。

当前 MVP 实现是上述目标的受限子集：搜索窗口从当前已读位置起最多向前 50 个规范化字符；规范化忽略标点、空格和硬换行并保留字母数字与 CJK 字符。窗口内唯一精确的 ASR 后缀命中可由单个事件立即跃迁到句内或跨句位置；重复短语、窗口外命中和自动后退均保持不动。LCS、二元组相似度、覆盖率和长度平衡继续为普通跟随提供小错字、少量口头语容错；短文本使用更高置信门槛，未来句还要求明确分差。partial 会单调更新句内 UTF-16 原文位置并驱动完整行上移；一次话语结束后，新 Session 可从已保存位置继续。累计与增量 ASR 分别只在有界候选窗口内做模糊匹配，避免长稿件远跳。非精确候选仍需两个相同 partial 才提交整句，final utterance 达到句内完成阈值后可立即提交；候选永不小于当前锚点。完整 token 权重、拼音同音模型、跨段落索引和离线评测调参仍属延期项。

M11-PR1 已把上述定位规则收敛为纯值 `ReadingPositionEngine`：输入为脚本及其版本、当前位置、转写片段、partial/final 语义和只含数值的稳定证据；输出为 `stay / advance / jump`，reason/evidence 不包含稿件或转写文本。脚本版本不一致时 fail-closed 保持。`TeleprompterController` 继续拥有识别 generation、Session 生命周期和状态发布，但不再自行持有候选阈值、稳定计数或跃迁判定，只应用 Engine 的目标位置。保留的 `TeleprompterScriptAligner` 是兼容入口和底层确定性匹配原语。

M11-PR2 在 Controller 边界加入纯值 `ReadingPositionUndoState`：记录只含脚本版本、独立 alignment generation 和跃迁前后锚点。只有 `.jump` 被成功应用且未进入完成态时记录；后续 `.advance` 或不兼容上下文立即清除。兼容的一次话语 rollover 保留记录，避免 final 后按钮在用户操作前消失；消费时仍重新校验脚本版本、定位代际和当前目标锚点。撤销不是 Engine 自动后退，而是手机端用户命令。

M11-PR3 新增纯值 `TeleprompterPositionCheckpoint` 与 `TeleprompterCheckpointStore`：checkpoint 仅含 schema、稳定 script identity、不可逆内容版本标识、句子索引和句内原稿 UTF-16 位置。仅全部兼容时恢复；损坏、未知 schema、身份/内容版本不符和越界均类型化拒绝，并从安全默认位置启动。App adapter 把单稿件正文、checkpoint bytes、索引缓存与评测缓存放在一个 versioned envelope 中，删除通过一次记录替换完成。

M11-PR4 第一阶段把 TXT/Markdown bytes 解析留在 App/Infrastructure；Controller 仍只接收构造后的 `TeleprompterScript`。解析结果不携带文件名或路径，DOCX/PDF/云盘和多稿件列表仍延期。

### 8.2 特殊语音行为

| 行为 | 处理 |
|---|---|
| 静默少于 2 秒 | 保持 `FOLLOWING`，不移动 |
| 静默达到 2 秒 | `HOLDING_SILENCE`，冻结位置 |
| 静默达到 15 秒 | 继续保持，可降低状态亮度；绝不自动结束 |
| 即兴插话 | 局部窗口无可靠匹配则保持；回到原稿后恢复 |
| 重复一句 | 最近单调候选优先；不因重复自动后退 |
| 跳读窗口内后文 | 50 个规范化字符内唯一精确命中立即跃迁；重复短语保持 |
| 跳过窗口外内容 | 不自动跃迁；用户手动纠偏 |
| 用户改口 | 未确认 partial 可修订；已确认锚点不后退 |
| 环境声/音量变化 | 只影响状态提示，不作为推进证据 |

上表是目标行为。当前自动化已覆盖 50 字内唯一精确命中的单事件跃迁、窗口外保持、重复目标保持、即兴/歧义保持、重复 partial 后推进和 final 立即推进；实现中 `level` 事件明确不推进，但没有独立验收结果。显式 2 秒/15 秒静默状态、复杂 partial 修订与噪声语料尚未实现或未验证。

## 9. 状态机：已实现 MVP 与目标增强

### 9.1 当前已实现

当前 `TeleprompterPhase` 是精简状态机：

```text
READY -> PREPARING -> LISTENING <-> PAUSED
              |            |
              |            └-> PREPARING（一次话语 finished 后自动轮换）
              |            └-> COMPLETED（末句确认完成）
              └----------------> MANUAL_FALLBACK

任意活动态 --background/shutdown/reset/revoke consent--> 取消当前 generation/session
```

- 无脚本通过 `script == nil` 与 user-safe error 表达，没有独立 `EMPTY` enum；
- `.finished` 自动轮换为下一次识别 Session；fake session 已覆盖轮换和旧事件拒绝，真实连续性未验证；
- background 会同步使 generation 失效、取消事件任务并立即发起 session cancellation；shutdown 会等待所有已发起 cleanup 完成；
- 明确撤销云端同意会立即取消 Session 并进入手动模式；
- `COMPLETED` 已作为独立 phase 实现，停止当前 Session，显示完成提示，并允许上键从首句重新开始；`SEARCHING`、`HOLDING_SILENCE`、`UNCERTAIN`、`REACQUIRING` 和 `INTERRUPTED` 尚未作为独立 phase 实现。

### 9.2 目标增强状态机（保留为后续规格）

```text
EMPTY -> PREPARING -> READY -> STARTING_CAPTURE -> SEARCHING_ANCHOR
                                              └-> DEGRADED_MANUAL

SEARCHING_ANCHOR -> FOLLOWING <-> HOLDING_SILENCE
        |              |   └-> UNCERTAIN -> FOLLOWING
        |              └-> MANUAL_OVERRIDE -> REACQUIRING -> FOLLOWING
        └-> DEGRADED_MANUAL

FOLLOWING / HOLDING / UNCERTAIN / MANUAL
        <-> PAUSED
         -> INTERRUPTED -> SEARCHING_ANCHOR 或 DEGRADED_MANUAL
         -> COMPLETED
         -> FAILED
```

### 9.3 状态定义与实现映射

| 状态 | 进入条件 | HUD 短文案 | 实现映射/状态 |
|---|---|---|---|
| `EMPTY` | 无有效讲稿 | 请导入讲稿 | 部分：以 `script == nil` + error 表达 |
| `PREPARING` | 正在规范化、索引、测量 | 正在准备 | 部分：已有 `.preparing`，但未细分脚本准备与 Session 准备 |
| `READY` | 讲稿和页面就绪，未采集 | 上键开始 | 已实现并有 Core 自动化覆盖 |
| `STARTING_CAPTURE` | 权限/recognizer/session 启动中 | 正在听 | 部分：包含在 `.preparing` |
| `SEARCHING_ANCHOR` | 尚无稳定语音位置 | 正在定位 | 延期：包含在 `.listening`，未独立呈现 |
| `FOLLOWING` | 有确认锚点且持续收到匹配 | 跟随中 | 已实现为 `.listening`；受限前向算法有自动化覆盖 |
| `HOLDING_SILENCE` | 连续静默 ≥2 秒 | 已暂停跟随 | 延期：无显式计时状态 |
| `UNCERTAIN` | 候选歧义或连续低置信度约 1–1.5 秒 | 未确定·左右调整 | 部分：对齐器会保持，但无独立 phase/HUD 文案 |
| `MANUAL_OVERRIDE` | 用户左右移动 | 手动定位 | 部分：左右调整已实现，但没有独立 phase |
| `REACQUIRING` | 从用户指定句重新匹配 | 重新定位 | 部分：下键会重启识别，但没有独立 phase |
| `PAUSED` | 用户短按上键 | 已暂停 | 已实现并有 Core 自动化覆盖 |
| `DEGRADED_MANUAL` | 权限、网络、ASR 不可用或用户选择 | 手动模式 | 已实现为 `.manualFallback`；拒绝同意/权限/准备失败/流失败均降级 |
| `INTERRUPTED` | 电话、音频路由、App 生命周期中断 | 音频中断 | 部分：background 取消并暂停；电话/路由专用语义延期 |
| `COMPLETED` | 在末尾确认完成 | 已结束 | 已实现：停止 Session，进度 100%，上键从首句重启；长按结束延期 |
| `FAILED` | 脚本不可用或不可恢复的内部错误 | 无法开始 | 部分：空稿和 user-safe error 已有，未建立独立 phase |

当前实现以 Controller `generation` 隔离 Reset、新脚本、暂停/恢复、后台、shutdown、撤销同意和手动跳转后的旧事件；自动化已覆盖多个迟到事件路径。独立 run id 与供应商 sequence 仍是连续识别端口的后续规格。

## 10. 纠偏、跳转与失败处理

| 情况 | 系统行为 | 用户恢复 | 当前状态 |
|---|---|---|---|
| 重复短句造成多个候选 | 保持当前行；目标 HUD 显示“未确定” | 左右选句或下键重捕获 | 部分：保持已实现；专用文案延期 |
| ASR 跳到后文 | 当前只允许在向前 50 个规范化字符内跃迁；唯一精确命中立即生效，非精确候选仍要求连续证据 | 窗口外内容用右键逐句调整 | 50 字跃迁已实现；跨段长按延期 |
| 用户回讲前文 | ASR 不自动后退 | 左键人工回退 | 已实现并有 Core 自动化覆盖 |
| 麦克风或 Speech 权限拒绝 | 进入纯手动 | 授权后下键显式重试 | 已实现；真实系统权限 UI 未验证 |
| 网络断开且只能云端识别 | 保留当前位置并在 stream failure 后转手动 | 下键显式重试 | 部分：失败降级已实现；1 秒目标和网络恢复路径未验证 |
| ASR 流卡住 | 目标由 watchdog 判定不可用 | 重建一次；再失败转手动 | 延期 |
| recognizer 单次时长上限 | `.finished` 后自动创建下一次 Session；页面锚点不重置 | 无需用户操作 | 自动化通过；live/device 连续性未验证 |
| 电话/音频路由中断 | 目标为停采集、冻结、进入 Interrupted | 恢复后从当前句重新定位 | 延期 |
| App 进入后台 | 立即使 generation 失效、取消事件任务并发起 Session cancellation，页面进入暂停 | 回前台后用户明确继续 | 自动化通过；设备生命周期未验证 |
| 宿主 shutdown | 立即取消当前消费并发起当前/待清理 Session cancellation，等待清理结束 | 无 | 自动化通过；设备生命周期未验证 |
| 眼镜断连 | 目标为停止采集并保留位置 | 重连后明确继续 | 延期 |
| 空白稿件 | 不进入可跟随态，显示安全错误 | 重新粘贴或导入并载入 | 已实现；TXT/Markdown 的空白、非法 UTF-8 与不可读文件均返回类型化失败，且不覆盖当前稿件 |
| 超长讲稿 | 当前截取到 20,000 个 `Character` | 缩短或分稿 | 已实现上限；分块索引延期 |
| 热状态/低电量 | 降低非必要刷新，优先保持文本 | 用户可切纯手动 | 延期/设备未验证 |

## 11. 隐私、离线与安全

### 11.1 能力优先级

```text
当前：经用户知情同意的云端 ASR > 纯手动模式
后续：设备端 ASR（设备与语言支持）> 云端 ASR > 纯手动模式
```

- 当前云端 ASR 同意由 App 自有 `TeleprompterSettings` 持久化，首次/无记录时默认 `false`；未同意时不请求麦克风、不准备 Session，仍可左右键手动使用。
- 控制面板明确说明开启后朗读音频会发送至配置的云端语音识别服务，并说明稿件正文不会作为文本上传。
- 提词器 Live Composition 只依赖 `SpeechCredentialProvider`/`SpeechCredentialLease`，该 lease 的描述会隐藏 secret；它不能取得 LLM/搜索能力。
- 设备端 ASR 尚未实现，不能把官方 API 的“可能支持”写成当前产品能力。
- 网络恢复不得静默恢复上传，必须由用户显式重试；当前没有自动网络恢复上传逻辑，但真实网络切换尚未验证。

### 11.2 数据边界

- 当前 App 将脚本草稿和云端同意保存在本地 `UserDefaults`，脚本长度限制为 20,000 个 `Character`；尚未保存位置 checkpoint。
- 当前功能代码没有新增原始音频或完整 partial/final 转写持久化，也没有新增提词器遥测；真实供应商的数据处理仍须按其服务协议单独验证。
- 暂停、撤销同意、后台和 shutdown 已实现 Session cancellation；后台/shutdown 的立即取消与迟到事件隔离有自动化覆盖。眼镜断连专用处理尚未实现。
- “删除讲稿同时删除索引、checkpoint 和自定义模型数据”仍是后续删除闭环要求；当前没有专用删除流程。
- 若后续加入遥测，只允许聚合值：状态时长、跳转计数、延迟桶、错误枚举和是否使用手动模式；不得包含文本片段。
- 明确禁止在驾驶/骑行等安全关键活动中使用；权限文案不得暗示可以秘密记录他人。

## 12. MVP 与后续范围

### 12.1 已实现的首版 MVP

- 手机端粘贴/编辑并载入讲稿，脚本草稿本地持久化并限制为 20,000 个 `Character`；
- 删除空格与 Tab、把连续换行折叠为一个 `/` 的本地分句、规范化、有界向前模糊匹配和重复 partial 稳定门槛；
- 复用供应商中立的一次话语 `SpeechRecognitionSession`，结束后自动轮换；
- App 持久化云端 ASR 同意且默认拒绝；拒绝时保留纯手动模式；
- speech-scoped credential boundary，不向提词器暴露 LLM/搜索凭据；
- 8:3 HUD 使用 TextKit 完整行测量，固定显示已读/当前/未读 3 行，采用 32%/100%/68% 三档绿色；
- 四向键短按、暂停/继续、当前句重启识别、末句完成/从头重启和纯手动降级；
- background/shutdown/撤销同意的立即取消、generation 隔离和迟到事件拒绝；
- Core fake session、聚焦 App/HUD 自动化覆盖；无 LLM。

### 12.2 已从首版 MVP 延期

- 长按上一段/下一段/结束等动作和长短按互斥；
- 专用连续 ASR 事件端口、显式 sequence、静默/不确定/中断细分状态；
- 完整 token-to-original range、段落索引和长稿分块索引；
- 多稿件 ScriptRepository、设备端 ASR、遥测；
- live provider 与物理设备验证未通过前，不将自动轮换称为“无缝”。

### 12.3 Later

- Apple 设备端识别与自定义语言模型/词表；
- 英文及更多语言的独立 tokenizer/eval corpus；
- DOCX、PDF、OCR、云盘和跨设备同步；
- 书签、关键词强调、固定滚速和外部遥控；
- 导播端、排练分析、多演讲者协作；
- 更长会话的供应商切换和本地模型。

## 13. 指标与初始目标

### 13.1 北极星指标

**Confirmed Follow Coverage**：在有效说稿时间内，HUD 当前行与独立标注的真实位置相差不超过 ±1 行的时间占比。

该指标需要离线或测试场景的独立 ground truth；线上不上传讲稿/转写来计算。

### 13.2 诊断与护栏

| 指标 | 初始受控测试目标 | 说明 |
|---|---:|---|
| 首次稳定定位时间 | ≤2.0 秒 | 从出现可识别语音到稳定锚点 |
| 可见页面跟随延迟 p95 | ≤1.2 秒 | 受控音频与目标设备上测量 |
| 错误前跳 | <1 次/1000 中文字符 | 定义为超过 ground truth +1 行且持续 |
| ASR 自动后跳 | 0 | 硬护栏 |
| 人工纠偏后重新捕获 p95 | ≤2.0 秒 | 下键或手动跳转后 |
| 半行/半字裁切 | 0 | 所有支持字体大小、动态安全区组合 |
| 每 10 分钟人工纠偏次数 | 建立基线后定目标 | 先分重复句、噪声、跳读等原因 |
| `UNCERTAIN` 时间占比 | 建立基线后定目标 | 不能靠激进跳转“优化” |
| 云端模式知情确认率 | 100% | 未确认不得上传 |
| 暂停/后台后的音频上传 | 0 | 隐私硬护栏 |

产品漏斗：成功导入率、开始率、完成率、主动结束率、手动模式占比、权限拒绝后的可继续率。所有事件不得携带脚本文本。

## 14. Given / When / Then 验收标准

状态含义：**通过（自动化）**仅表示已有自动化直接覆盖该核心行为；**部分实现**表示已有子集但尚未满足整条标准；**延期**表示首版未实现；**未验证**表示实现可能存在，但当前证据不足。下表不把 Package 总通过数等同于每条标准均通过。

| 条目 | 当前状态 | 证据/缺口摘要 |
|---|---|---|
| GWT-01 | 部分实现 | 粘贴、TXT/Markdown 导入、载入与分句已覆盖；完整 token/range 索引延期 |
| GWT-02 | 通过（Core + App 自动化） | 空稿、空文件、非法 UTF-8、超长、重复和不支持类型均有明确结果，失败不覆盖当前稿件 |
| GWT-03 | 部分实现 | TextKit 完整 Unicode 行片段自动化通过；完整预处理 range 索引延期 |
| GWT-04 | 通过（聚焦 App/HUD 自动化） | 3 条完整测量行有覆盖 |
| GWT-05 | 通过（聚焦 App/HUD 自动化） | 默认 iPhone 17 Pro Max 投影尺寸可容纳 3 条完整正文行 |
| GWT-06 | 未验证 | 本轮聚焦证据未单独证明提词器 Reduce Motion 路径 |
| GWT-07 | 通过（Core 自动化） | fake session 启动后进入 listening |
| GWT-08 | 部分实现 | preparing 再按会取消/暂停，不是原规格中的重复 start 幂等 |
| GWT-09 | 部分实现 | 少于 4 个规范化字符不推进；“两个常见 token”模型未实现 |
| GWT-10 | 通过（Core 自动化） | 两个相同 partial 后提交唯一前向候选 |
| GWT-11 | 未验证 | 未单独覆盖 partial 被 final 修订的完整序列 |
| GWT-12 | 通过（Core 自动化） | 对齐器永不提出后退位置 |
| GWT-13 | 通过（Core 自动化） | 重复/歧义短语保持当前锚点；无独立 Uncertain phase |
| GWT-14 | 通过（Core 自动化） | 50 字内唯一精确命中由单个 partial 立即跃迁；窗口外与重复目标保持；非精确候选仍走稳定门槛 |
| GWT-15 | 通过（Core 自动化） | 即兴文本不匹配时保持锚点 |
| GWT-16–17 | 延期 | 无 2 秒/15 秒静默计时 phase |
| GWT-18 | 已实现，未单独验收 | level 事件被忽略；当前测试矩阵无独立结果 |
| GWT-19 | 通过（Core 自动化） | 手动纠偏重建 Session 并拒绝旧事件 |
| GWT-20 | 已实现，未单独验收 | 索引 clamp 保持首句/末句，无专用边界反馈测试 |
| GWT-21 | 延期 | 长按未实现 |
| GWT-22 | 部分实现 | 下键重启当前锚点已实现；未单独验证新 generation 全路径 |
| GWT-23 | 通过（Core 自动化） | 撤销云端同意后转手动并拒绝迟到事件 |
| GWT-24 | 通过（Core 自动化） | background 后暂停并拒绝迟到事件；其他 paused 来源未全量覆盖 |
| GWT-25 | 部分实现 | 长按结束延期；完成态及暂停/后台/reset/shutdown checkpoint 已实现 |
| GWT-25A–25E | 通过（Core + App Simulator 自动化） | 手机按钮按需出现；一次性恢复跃迁前锚点；重复点击和旧事件无效；人工/脚本/reset/shutdown/完成/普通推进使记录失效；兼容 rollover 保留且不兼容重锚定拒绝。真机触达与真实 ASR 未验证 |
| GWT-26 | 通过（Core + App 自动化） | 同意默认拒绝；不请求权限/不准备 Session；手动仍可用 |
| GWT-27 | 部分实现 | stream failure 转手动并保留锚点；1 秒网络目标未验证 |
| GWT-28 | 已实现，未验证 | 无静默自动恢复上传逻辑；真实网络恢复未跑 |
| GWT-29 | 部分通过 | background 立即取消并保存 checkpoint 有自动化；真实眼镜断连事件延期 |
| GWT-30 | 延期 | 电话/音频路由专用恢复未实现 |
| GWT-31 | 通过（Core 自动化） | one-shot auto-rotation 与旧事件拒绝通过；live/device 连续性未验证 |
| GWT-32 | 通过（Core + App 自动化） | 手机确认后单 envelope 清理稿件、checkpoint、索引与评测缓存；真机交互未验证 |
| GWT-33 | 延期 | 当前未新增提词器遥测；未来需隐私 payload 测试 |

### 14.1 导入与排版

1. **Given** 有效的简体中文 UTF-8 TXT，**When** 用户导入，**Then** 保留原文并生成可回映的句、段、token、测量行索引。
2. **Given** 空白或无法解码的文件，**When** 导入，**Then** 不进入 Ready，并给出可操作错误，不修改原文件。
3. **Given** 一句包含 emoji、组合附加符或罕见汉字，**When** 分行，**Then** 所有 range 位于 Swift `Character` 边界。
4. **Given** 安全高度可容纳 3 行，**When** 任意页面渲染，**Then** 恰好显示 3 条完整正文行，无半行、半字和省略号。
5. **Given** 默认 iPhone 17 Pro Max 的 8:3 投影，**When** 渲染题词器，**Then** 正文区域按 14 pt 字体完整容纳 3 行；新增显示配置若无法满足该条件，不得作为受支持配置发布。
6. **Given** 开启 Reduce Motion，**When** 锚点推进，**Then** 页面直接吸附到新完整行，无逐字或滑动动画。

### 14.2 ASR 跟随

7. **Given** Ready 且权限可用，**When** 短按上键，**Then** 只创建一个识别 session 并进入 Searching。
8. **Given** 连续按两次开始，**When** 第二次发生在启动中，**Then** 不创建第二个 session。
9. **Given** partial 只有两个常见短词，**When** 到达，**Then** 只更新候选，不提交页面推进。
10. **Given** 连续事件满足稳定门槛，**When** 指向前方唯一候选，**Then** 确认锚点并将目标完整行置中。
11. **Given** partial 后续被 final 修订，**When** 候选改变，**Then** 只替换未确认候选，不回滚已确认行。
12. **Given** 用户重复刚说的一句，**When** ASR 再次命中，**Then** 页面不自动后退。
13. **Given** 脚本中存在多个相同短语，**When** 评分仍歧义，**Then** 进入 Uncertain 并冻结，不随机选择。
14. **Given** 用户突然朗读当前已读位置后 50 个规范化字符内的后文，**When** 一个 ASR 事件的后缀在窗口内唯一精确命中，**Then** 立即跃迁到命中结束位置；若目标起点超过 50 个字符、目标重复或命中不可靠，**Then** 保持当前位置。
15. **Given** 用户即兴插话，**When** 局部窗口没有可靠匹配，**Then** 保持当前锚点；用户回到讲稿后恢复。
16. **Given** 连续静默达到 2 秒，**When** 无新匹配，**Then** 进入 Holding，不移动、不结束。
17. **Given** 静默超过 15 秒，**When** 会话仍有效，**Then** 继续保留位置，不把静默当作完成。
18. **Given** 仅收到音量/VAD 事件，**When** 无文本证据，**Then** 不推进脚本。

### 14.3 手动控制与代际

19. **Given** Following，**When** 短按左键，**Then** 立即定位上一句，并使旧候选失效。
20. **Given** 当前在首句，**When** 左移，**Then** 保持首句并显示边界反馈，不循环到末尾。
21. **Given** Following，**When** 长按右键，**Then** 跳到下一段，且不额外触发短按下一句。
22. **Given** 用户手动定位当前句，**When** 短按下键，**Then** 从该句建立新 generation 并进入 Reacquiring。
23. **Given** 用户切换纯手动，**When** ASR 仍到达旧事件，**Then** 事件被忽略且页面不动。
24. **Given** Paused，**When** 收到网络或 ASR 回调，**Then** 不更新锚点；再次继续后从当前句重新定位。
25. **Given** 任意运行态，**When** 长按上键，**Then** 停止采集、保存 checkpoint、进入 Completed，且不触发短按暂停。
25A. **Given** 当前发生一次可撤销自动 `jump`，**When** 手机正在显示提词器控制面板，**Then** 显示“撤销刚才的自动跳转”；无记录或已失效时不显示。
25B. **Given** 撤销记录仍与脚本版本、定位代际和当前锚点兼容，**When** 用户点击手机按钮，**Then** 一次性恢复跃迁前锚点、取消当前 Session，并在原跟随态下创建新 Session。
25C. **Given** 已完成一次撤销，**When** 用户重复点击或旧 Session 继续发送 partial/final，**Then** 页面不再回退且旧事件被拒绝。
25D. **Given** 存在撤销记录，**When** 用户左右纠偏、下键重锚定、替换脚本、reset、shutdown、完成或发生后续普通自动推进，**Then** 记录立即失效。
25E. **Given** 自动 rollover 保持相同脚本与定位上下文，**When** 新 Session 接管，**Then** 撤销仍可用；若脚本版本、定位代际或目标锚点不匹配，**Then** fail-closed。
25F. **Given** 存在兼容 checkpoint，**When** App 重新建立同一 script identity 与内容版本，**Then** 恢复句子与句内原稿位置；schema、身份、版本或边界不兼容时从安全默认位置开始并返回类型化原因。

### 14.4 故障、隐私与恢复

26. **Given** 设备不支持本地 ASR，**When** 用户未同意云端处理，**Then** 进入纯手动且讲稿仍可使用，不上传音频。
27. **Given** 云端 ASR 正在运行，**When** 网络断开，**Then** 1 秒内冻结并转纯手动，保留位置。
28. **Given** 网络恢复，**When** 用户未显式重试，**Then** 不自动恢复音频上传。
29. **Given** App 进入后台或眼镜断连，**When** 生命周期事件到达，**Then** 停止采集/上传并保存 checkpoint。
30. **Given** 电话或音频路由中断，**When** 恢复，**Then** 从当前句进入 Searching，而不是从脚本开头重启。
31. **Given** recognizer rollover，**When** 新底层 session 接管，**Then** run id、页面和确认锚点保持，且旧 session 事件被拒绝。
32. **Given** 用户删除讲稿，**When** 删除完成，**Then** 原稿、索引、checkpoint 和相关本地模型数据均不可再读取。
33. **Given** 分析事件被记录，**When** 检查 payload，**Then** 不含脚本文本、识别文本、音频、文件名或可逆文本哈希。

## 15. 确定性测试矩阵

所有自动化测试使用 fake recognition session、固定事件序列、注入时钟和固定字体测量结果；不得消耗真实凭据。

| ID | 层级 | 语料/条件 | 注入事件 | 预期不变量 | 当前状态 |
|---|---|---|---|---|---|
| T01 | Unit/Parser | 空字符串、纯空白 | 导入 | typed invalid-script；不建 run | 通过（Core） |
| T02 | Unit/Parser | CRLF、Tab、连续空格、空段落、中英文标点 | 预处理 | displayText 不含空格、Tab 或空句；连续段落边界只保留一个 `/`；matchTokens 忽略 `/` | 通过（Core）；完整原文映射延期 |
| T03 | Unit/Parser | emoji、组合字符 | 分句/分行 | range 均为 `Character` 边界 | 部分：HUD TextKit 通过；预处理 range 延期 |
| T04 | Unit/Layout | 可放 3 行 | 固定测量 | 3 完整行；无截断/省略号 | 通过（聚焦 App/HUD） |
| T05 | Unit/Layout | iPhone 17 Pro Max 默认投影 | 固定测量 | 14 pt 正文完整容纳 3 行 | 通过（聚焦 App/HUD） |
| T06 | Unit/Layout | 极长无空格 token | 固定宽度 | 字素安全换行；不无限循环 | 未单独验证 |
| T07 | Snapshot/HUD | Ready/Searching/Following | 固定页面 | 状态与进度在预算内，当前行视觉层级明确 | 部分：HUD Mapper 通过；非完整 snapshot |
| T08 | Snapshot/HUD | 新增显示配置/安全区 | 固定页面 | 必须容纳 3 条完整正文行，否则配置不通过 | 默认配置通过；其他配置待逐项验证 |
| T09 | Unit/Engine | 连续唯一句 | 稳定 partial/final | 单调推进到唯一候选 | 通过（Engine/Core） |
| T10 | Unit/Aligner | 仅两个常见词 | partial | 候选不提交 | 部分：4 字符阈值已实现 |
| T11 | Unit/Engine | partial 被 final 修订 | 两事件 | partial 需稳定证据；final 可立即提交；确认锚点不回滚 | 通过（Engine 的 partial 稳定/final 立即路径）；复杂修订语料延期 |
| T12 | Unit/Engine | 相同短语出现 3 次 | 命中短语 | 保持/Uncertain，不随机远跳 | 通过（Engine/Core，类型化 ambiguous stay；无独立 Uncertain phase） |
| T13 | Unit/Aligner | 重复上一句 | ASR 重复 | 自动后跳数为 0 | 通过（Core） |
| T14 | Unit/Aligner | 即兴插入 20 秒 | 无匹配后回稿 | 插话时保持；回稿后恢复 | 部分：文本保持通过；20 秒计时延期 |
| T15 | Unit/Engine + Controller | 跳读 50 字内唯一后文 | 单个精确 partial | 立即跃迁到句内或跨句位置 | 通过（Engine/Core，第 50 字边界） |
| T16 | Unit/Engine | 目标超过 50 字或窗口内重复 | 单个匹配 | 保持当前位置，不猜测跳转 | 通过（Engine/Core，第 51 字与歧义保持） |
| T17 | Unit/Aligner | 中英文数字/英文产品名 | 规范化事件 | 按定义命中；displayText 未改写 | 部分：字母数字/CJK 规范化已实现 |
| T18 | Unit/State | 开始双击 | 同 generation 两次 start | 仅一个 session | 未按该语义实现 |
| T19 | Unit/State | Following | 时钟推进 1.9 秒静默 | 仍 Following，页面不动 | 延期：无静默时钟 |
| T20 | Unit/State | Following | 时钟推进 2.0 秒静默 | Holding，页面不动 | 延期：无 Holding phase |
| T21 | Unit/State | Holding | 时钟推进到 15 秒 | 不完成、不重置 | 延期：无 Holding phase |
| T22 | Unit/State | 任意位置 | 仅 level/VAD | 锚点不变 | 已实现，未单独验证 |
| T23 | Unit/State | 手动左移 | 旧 generation ASR 到达 | 旧事件忽略 | 通过（Core） |
| T24 | Unit/State | 纯手动 | partial/final 到达 | 锚点不变 | 通过（Core 撤销同意路径） |
| T25 | Unit/State | Paused | ASR/网络事件 | 状态和锚点不变 | 通过（Core background 路径） |
| T26 | Unit/Control | 长按左/右/上/下 | 短按回调随后到达 | 长按与短按互斥，仅一次动作 | 延期：长按未实现 |
| T27 | Unit/Control | 首句/末句 | 越界按键 | 保持边界，不环绕 | 已实现，未单独验证边界反馈 |
| T28 | Unit/Failure | 权限拒绝 | start | Manual；不重试弹窗；可读稿 | 部分：代码路径已实现；默认拒绝同意路径通过 |
| T29 | Unit/Failure | 云端网络断开 | injected clock + error | ≤1 秒进入 Manual；保留锚点 | 部分：stream failure 降级通过；时间/真实网络未跑 |
| T30 | Unit/Privacy | 网络恢复 | 无用户动作 | 不创建云端 session | 已实现，真实网络未验证 |
| T31 | Unit/Lifecycle | App 后台/眼镜断连 | lifecycle event | 采集停止；checkpoint 写一次 | 部分：后台取消与 checkpoint 去重写入通过；真实眼镜断连事件延期 |
| T32 | Unit/Lifecycle | 电话中断后恢复 | interruption events | 当前句 Searching；不从头开始 | 延期 |
| T33 | Unit/Concurrency | reset 后旧事件 | old run id/sequence | 全部忽略；新 run 不污染 | 通过（Core generation） |
| T34 | Unit/Adapter | recognizer rollover | 两 session 交叠 | 序列单调；旧 session 尾事件忽略 | 通过（Core fake session）；live/device 未验证 |
| T35 | Unit/Storage | 删除讲稿 | delete | 原稿/索引/checkpoint/评测缓存单记录清空并旋转 identity | 通过（Core + App 自动化）；真机确认框未验证 |
| T36 | Unit/Telemetry | 正常/错误全路径 | capture events | payload 无文本、音频、文件名/可逆哈希 | 延期：尚无提词器遥测 |
| T37 | Performance | 60 分钟长稿 | 固定流 | 内存有界；局部搜索耗时不随全文线性恶化 | 未运行 |
| T38 | App Integration | fake ASR + Experience | 四向操作 | 四向操作继续走通用 control state；仅手机撤销读取提词器可用状态并调用显式命令 | 通过（Core/App/架构门禁的相关覆盖） |
| T39 | Simulator | 8:3、多状态、Reduce Motion | UI 操作 | 页面完整行、可读、无动画违规 | 部分：App/HUD 逻辑通过；交互式 UI/Reduce Motion 未跑 |
| T40 | Live Provider | 普通话、静默、插话、噪声 | 真实 ASR | 测量首次定位、p95 延迟、错误跳转；不预设通过 | 未运行 |
| T41 | Physical Device | 真实眼镜 10/30/45 分钟 | 讲稿+四键 | 分别记录可读性、疲劳、按键、音频路由、热与电量 | 未运行 |
| T42 | Unit/Engine | 脚本版本不一致 | 陈旧识别事件 | fail-closed 保持；决定对象不含文本 | 通过（Engine） |
| T43 | Unit/Concurrency | 相同 Engine 输入 | 64 个并发调度任务 | 所有结果完全一致 | 通过（Engine） |
| T44 | Unit/Undo Contract | 最近自动跃迁 | consume 两次 | 第一次恢复 source；第二次为 nil | 通过（Core） |
| T45 | Unit/Controller | 自动 jump 后点击手机撤销 | 当前与旧 Session 事件 | 恢复旧锚点；取消当前 Session；旧 partial/final 拒绝 | 通过（Core fake Session） |
| T46 | Unit/Controller | 人工纠偏、脚本替换、reset、shutdown、完成、普通推进 | 各失效动作 | 撤销不可用且不能改变新位置 | 通过（Core） |
| T47 | Unit/Controller | 自动 rollover 后撤销 | 三个 fake Session | 兼容 rollover 保留；只取消当前 Session；新 Session 从旧锚点开始 | 通过（Core fake Session）；live provider 未验证 |
| T48 | App/UI Policy | 提词器/其他体验 × 有/无记录 | 状态组合 | 仅提词器且有记录时显示手机按钮 | 通过（App Simulator 策略）；真机视觉未验证 |
| T49 | Unit/Checkpoint | schema/identity/content version/位置组合 | restore | 仅全部兼容时恢复；其余类型化拒绝到安全默认 | 通过（Core） |
| T50 | Unit/Checkpoint Codec | 正常、损坏与未知 schema bytes | encode/decode | 正常 round-trip；损坏/未知版本 fail-closed；记录无稿件/转写/provider payload | 通过（Core） |
| T51 | Unit/Controller | partial、暂停、后台、shutdown、自动/显式完成 | 生命周期序列 | partial 不落盘；边界写入；相同位置去重；完成保存末尾位置 | 通过（Core fake store） |
| T52 | App/Storage | 旧 script key、versioned envelope | App 初始化 | 旧稿迁移一次；identity 保持；checkpoint 可恢复 | 通过（App Simulator） |
| T53 | App/Storage | 稿件内容变化、损坏 checkpoint | 编辑/启动 | 清空派生数据；损坏位置不覆盖正文且回到安全默认 | 通过（App Simulator） |
| T54 | App/Import | TXT/Markdown、空白、非法 UTF-8、超长、重复、不支持类型 | bytes parse | 成功返回正文；失败/重复不覆盖；结果无文件名和路径 | 通过（App Simulator parser）；真实文件提供器未验证 |
| T55 | Unit/Controller | 运行中删除后旧 Session 回调 | delete + late events | 持久化确认后清空状态；旧事件不能复活稿件 | 通过（Core fake Session） |

## 16. 发布门与证据要求

建议按以下顺序验收，任何后层成功都不能替代前层证据：

1. **已通过**：本次 SingleGreenGlassesKit 全量套件 265/265；
2. **已通过**：本次 SingleGreenUser App Simulator 全量 93/93，0 failures，0 skips，运行于 iPhone 17 Pro / iOS 26.5；
3. **已通过**：本次 Internal Debug iphoneos archive/export、Internal Debug Simulator build/能力扫描和 User Release Simulator build；历史 Release generic iphoneos build 仍只作为历史证据；
4. **部分通过**：本次 credential isolation、repository hygiene、privacy logging、VAD privacy、secret scan、architecture gates 和 public API updater 安全自检已通过；final public API baseline 因本机工具链低于仓库锁定版本而按设计未运行；
5. **未运行**：live provider 的 DeepSeek、搜索和 ASR 调用，包括普通话、噪声、静默、插话、跳读与 rollover 连续性；
6. **延期**：本轮按用户决定不执行设备 install/launch；2026-08-31 的历史安装记录不替代 2026-09-01 当前 checkout 的真机、物理眼镜显示、音频路由和人工可读性证据。

PromptSmart 对 VoiceTrack 使用专利表述。商业发布前应由合格人员做独立的专利/自由实施审查；本文不是法律意见，也不据此判断侵权与否。

## 17. 当前验证状态（2026-09-01）

本文同时记录产品规格与目前实现证据，但不把自动化通过外推为真实服务或物理设备通过。本次修复已重新运行 Core 与 App 自动化；真实服务和物理设备仍是独立门。

| 证据类别 | 当前状态 | 备注 |
|---|---|---|
| 文档静态检查 | 已通过：逐文件 whitespace check 与敏感信息模式扫描 | 未发现 diff 空白错误或常见密钥模式；不验证业务 |
| 最终 Core 自动化 | 本次全量已通过：SingleGreenGlassesKit 265/265；checkpoint 聚焦 4/4；提词器聚焦回归 47/47 | 新增 schema/codec/兼容恢复、生命周期写入频率、显式完成、原子删除和迟到事件隔离覆盖；不代表真实服务通过 |
| 最终 App Simulator 全量 | 本次已通过：93/93，0 failures，0 skips；iPhone 17 Pro，iOS 26.5；`/tmp/SingleGreenDemo-M11-PR34-Final3-AppTests/Logs/Test/Test-SingleGreenUser-2026.09.01_00-21-14-+0800.xcresult` | SingleGreenUser App test target 全量通过，含本地 envelope/迁移/删除、TXT/Markdown parser、撤销策略与既有 HUD 回归；不等于真实文件提供器、live provider 或设备验证 |
| 本次内部版 App/HUD 聚焦复测 | 已通过：49/49，0 failures，0 skips；iPhone 17 Pro Max Simulator，iOS 26.5；`/private/tmp/SingleGreenDemo-ThreeLineFixTests/Logs/Test/Test-SingleGreenInternal-2026.08.31_14-27-37-+0800.xcresult` | 使用默认显示 Profile 与 440×956 容器计算实际投影，验证 14 pt 正文可完整容纳 3 行 |
| iphoneos 构建与导出 | 本次 Internal Debug archive/export 成功；版本 0.1（9）的 `SingleGreenInternal-Build9-M10.ipa` 已核验签名、内部 Bundle ID、能力标记和 SHA-256；历史 Release generic iphoneos build 仍为历史证据 | 测试包路径：`/Users/chenkemin/Documents/ChatGPT/单绿眼镜 Demo/测试包/Build-9-M10/SingleGreenInternal-Build9-M10.ipa`；构建与签名通过不等于具体设备 install/launch |
| 发布与隐私门禁 | 本次已通过：secret scan、repository hygiene、privacy logging、VAD privacy、architecture gates 与 11 个负向 fixture、七 Package strict-concurrency/WAE 561/561、User Release Simulator build、diff whitespace 和 public API updater 安全自检 | 实际 public API baseline 按用户决定未运行，延期至 2026-09-02 在 Xcode 26.6（17F113）/ Swift 6.3.3 执行；本轮未改写 baseline |
| Live provider | 未运行 | 未验证真实 DeepSeek、搜索、普通话 ASR、延迟、噪声或 one-shot auto-rotation 连续性 |
| 物理设备 install/launch | 本轮未运行，按用户决定延期至 2026-09-02 | 2026-08-31 有旧 checkout 的历史安装记录；不能证明当前 checkpoint/导入/删除、撤销、眼镜可读性、按键、音频路由、热与电量 |

本次 checkout 的 Core/App 自动化、架构边界、严格并发和敏感信息扫描已刷新；公共 API 基线仍需在仓库锁定工具链上复验。真实普通话 ASR、50 字跃迁与撤销、物理设备显示、音频路由和人工可读性体验继续作为独立证据门。
