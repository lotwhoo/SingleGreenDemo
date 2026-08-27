# 任务卡：自包含 Monorepo 与首个 Git 基线

## 问题与目标用户

当前 Xcode 工程通过 `../AiiOSstudy/VoiceChat/*` 引用三个本地 Swift Package。项目在当前 Mac 可运行，但克隆到其他机器后无法复现目录布局。目标用户是后续维护、测试、升级和分发该 Demo 的开发者。

## 本次目标

- 将 VoiceChatDomain、VoiceChatCore、LLMKit 的源码、测试和 Package manifest 纳入本仓库。
- 保持现有模块名称、边界和行为不变。
- 更新 Xcode、文档与测试命令，不再依赖仓库外路径。
- 完成清理后的 116 项回归和 iOS 签名构建。
- 创建当前仓库第一个可回退的 Git 基线提交。

## 非目标

- 不修改 ASR、LLM、搜索协议或产品交互。
- 不发布远程仓库、Tag、PR 或二进制。
- 不把 API Key、UserDefaults 或 Keychain 数据带入仓库。
- 不同步修改原 AiiOSStudy 仓库。

## 验收标准

1. 断开 `../AiiOSstudy` 路径后，Xcode Package Graph 仍能解析。
2. 三个 Package 位于 `Packages/`，且没有 `.build`、`.swiftpm`、`.DS_Store` 或用户状态。
3. 平台 14、Domain 10、Core 25、LLMKit 45、App 22 项测试全部通过。
4. `generic/platform=iOS` arm64 签名构建通过。
5. README 与架构报告只给出仓库内路径。
6. `main` 存在首个基线提交，提交后工作树干净。

## 相关代码路径

- `SingleGreenDemo.xcodeproj/project.pbxproj`
- `Packages/VoiceChatDomain`
- `Packages/VoiceChatCore`
- `Packages/LLMKit`
- `README.md`
- `docs/PROJECT_ARCHITECTURE_AND_UPGRADE_REPORT.md`
- `.gitignore`

## 实现步骤

1. 复制三个 Package，排除所有生成内容和用户状态。
2. 将 Xcode local package reference 改为 `Packages/*`。
3. 保持 Core 的 `../LLMKit` sibling 依赖。
4. 更新测试、构建、架构和来源说明。
5. 全量验证后创建 Git 基线提交。

## 测试矩阵

| 层级 | 验证 |
| --- | --- |
| Platform Core | Runtime、Experience、几何边界，14 项 |
| VoiceChatDomain | 对话领域状态，10 项 |
| VoiceChatCore | ASR、帧、gzip，25 项 |
| LLMKit | LLM、重试、工具和搜索，45 项 |
| App XCTest | Runtime 集成、设置、AI 编排，22 项 |
| iOS Build | 通用 iphoneos arm64 签名构建 |

## 风险与依赖

- 纳入仓库后，AiiOSStudy 上游变更不会自动同步；后续必须通过明确的 vendor 升级流程更新并记录来源提交。
- VoiceChatCore 当前有 Swift 6 Sendable 警告，LLMKit 测试有一处未使用变量警告；本任务不改变行为，警告治理另开任务。
- 原 AiiOSStudy 仓库没有发现许可证文件；这些模块属于用户当前本地工程，不应在未补许可信息前对外开源分发。

## 开放问题

无阻塞问题。未来如果三个 Package 需要被多个 App 独立复用，应拆成具有 LICENSE、语义版本和变更日志的独立远程仓库；当前阶段 monorepo 的可复现性收益更高。

## 完成记录

- 三个 Package 与 AiiOSStudy 来源基线逐文件对比一致。
- Xcode Package Graph 实际解析路径均位于本仓库 `Packages/`。
- Platform Core 14、VoiceChatDomain 10、VoiceChatCore 25、LLMKit 45 项测试通过。
- App-hosted XCTest 22 项通过。
- 合计 116 项测试，0 失败。
- 通用 `iphoneos arm64` Debug 签名构建成功。
- 未执行真实 API E2E；本任务不读取或使用用户凭证。
