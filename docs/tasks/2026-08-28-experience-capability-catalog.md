# M3 任务卡：Experience Capability Catalog

## 目标

让 Experience 自己声明稳定的宿主元数据、能力和动作；Runtime 提供统一目录与动作入口，手机模拟器控制面板只消费 descriptor，不再维护按 `ExperienceKind` 分支。

## 已完成契约

- `ExperienceDescriptor` 和 `ExperienceActionDescriptor` 由 Session 持有，使用不可变值。
- `ExperienceCatalog` 校验空目录、重复 kind、缺失 metadata、重复/空动作 ID、primary action 数量和无障碍字段，并返回 typed failures。
- 五个 raw ID/顺序固定为：`conversation`、`systemStatus`、`navigation`、`notification`、`caption`。
- AI 对话能力为 network、microphone、backgroundUpdates；其他四个内建本地体验无外部能力声明。能力仅是 declarative metadata，不是自动权限 gating。
- Runtime 对外提供 `availableDescriptors`、`selectedDescriptor`、`activeActions` 和 `performAction`；provider detail 由宿主注入。
- 次级 action grid 自适应动作数量；测试 fixture/example 提供新增体验目录项的复用 checklist。

## 事件来源与并发安全

M1 canonical `ExperienceSnapshot` 未改变。`ExperienceUpdate` 携带 opaque command token 或 spontaneous provenance；TaskLocal 捕获命令上下文，外部回调使用 `ExperienceUpdateSource.current`。Runtime 以 Session identity 和 token 过滤更新，action/reset/activation 以 `expectedKind` 定位，activation 中点再次检查。AI 侧以 `inputOperationGeneration` 拦截取消后的迟到 ASR start。

通知体验保留稳定语义：primary action 文案为“显示提醒”，`triggerAlert` 显示，`tap` 和 `swipeDown` 关闭。

## 验收证据

- SingleGreenGlassesKit 86/0。
- App-hosted XCTest 23/0。
- 紧邻 QA 的依赖回归：VoiceChatDomain 14/0、VoiceChatCore 25/0、LLMKit 59/0、StreamingTextKit 7/0。
- 相关测试合计 214/0；依赖套件为新鲜回归，未在 M3 直接范围重复计算。
- 通用 `arm64 + x86_64` Simulator build 通过。
- 最终 QA/评审无 P0–P2。
- xcresult：`/private/tmp/SingleGreenDemo-M3FinalReview/Logs/Test/Test-SingleGreenDemo-2026.08.28_02-49-02-+0800.xcresult`。

## 未完成验证

- 模拟器视觉对照和无障碍手工检查。
- 物理设备安装/启动、真实 ASR/LLM/Search 服务、真实眼镜光学验证。
