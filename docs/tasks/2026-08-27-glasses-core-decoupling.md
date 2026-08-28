# 眼镜核心与模拟器宿主解耦

## 目标

将工程分为两个可独立演进的责任边界：

- `SingleGreenGlassesKit`：设备无关的眼镜核心，包含 HUD 领域模型、Experience 合约、Runtime、内建 Experience、AI Ports 和对话 Controller。
- `SingleGreenDemo`：iPhone 相机模拟与调试宿主，包含相机、SwiftUI 渲染、控制面板、DisplayProfile、设置、Keychain 和真实服务适配器。

## 边界决策

- 核心包不引入 SwiftUI、UIKit、AVFoundation、VoiceChatCore 或 LLMKit。
- 控制面板只消费 Runtime 的 `ExperienceControlState`，不直接持有 `VoiceConversationController`。
- 生产 ASR/Agent 桥接保留在宿主，通过 `VoiceConversationDependencies` 注入核心。
- 原根 SwiftPM 工作区由正式 `SingleGreenGlassesKit` Package 取代，避免手工枚举 App 源文件。

## 验证证据

2026-08-27 执行：

| 边界 | 数量 | 结果 |
| --- | ---: | --- |
| SingleGreenGlassesKit | 41 | 通过 |
| VoiceChatDomain | 14 | 通过 |
| VoiceChatCore | 25 | 通过 |
| LLMKit | 59 | 通过 |
| StreamingTextKit | 7 | 通过 |
| App-hosted XCTest | 13 | 通过 |
| 合计 | 159 | 0 失败 |

- iPhone 17 Pro Simulator XCTest 结果包：`/tmp/SingleGreenDemo-DecouplingTests-Final/Logs/Test/Test-SingleGreenDemo-2026.08.27_23-49-38-+0800.xcresult`。
- `generic/platform=iOS Simulator` 的 arm64 + x86_64 无签名构建通过。
- 包边界静态扫描、diff 检查和凭证扫描在本任务收尾时执行。
- 本次未重新执行真机安装、启动或真实 ASR/LLM/Search 链路。
