# 本地 AI Packages

本目录保存 SingleGreenDemo 构建所需的四个本地 Swift Package，使仓库不再依赖开发者机器上的 sibling 目录。

## 来源基线

- 上游仓库：`git@github.com:lotwhoo/AiiOSstudy.git`
- 上游提交：`f05467c9243e9ac498e1e2874a08445d3380b034`
- 提交日期：2026-08-27
- 提交标题：`test: harden conversation and protocol boundaries`
- 纳入日期：2026-08-27

纳入时三个上游 Package 路径均没有未提交源码变更。`.build`、`.swiftpm`、`.DS_Store` 和 Xcode 用户状态未复制。

`StreamingTextKit` 是本项目内新建的通用模块，不属于上述 AiiOSStudy 同步基线。它封装打字策略、字素缓冲、Unicode 对齐和自动尾随判定。

## 依赖关系

```text
VoiceChatDomain   独立
LLMKit            独立
VoiceChatCore     → ../LLMKit（仅 ASRCLI 工具使用）
StreamingTextKit  独立
SingleGreenDemo   → VoiceChatDomain + VoiceChatCore + LLMKit + StreamingTextKit
```

## 升级流程

1. 记录目标 AiiOSStudy commit，并确认三个 Package 工作树没有未提交修改。
2. 只同步 `Package.swift`、`Sources/`、`Tests/` 和确有必要的 `Tools/`。
3. 不复制 `.build`、`.swiftpm`、用户状态、凭证或日志。
4. 对比公开 API、Package 平台版本和 Core → LLMKit 相对路径。
5. 依次运行三个上游 Package、`StreamingTextKit`、平台、App XCTest 和 iOS 构建。
6. 更新本文件的来源提交，并在提交信息中记录行为变化。

## 分发边界

上游当前没有发现 LICENSE、COPYING 或 NOTICE 文件。当前代码用于用户自己的本地工程；在对外开源或重新分发前，应先补充明确的许可证和第三方声明。`StreamingTextKit` 后续若单独发布，也需在 Package 根目录补充独立 LICENSE 和语义化版本策略。
