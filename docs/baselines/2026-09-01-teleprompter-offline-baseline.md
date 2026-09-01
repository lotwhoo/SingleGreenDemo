# 提词器离线评测基线（2026-09-01）

> 状态：本机开发基线，不是验收阈值
>
> 数据边界：只使用仓库内合成/脱敏 fixture；报告不包含稿件正文、转写片段、音频、文件名、路径、凭证或供应商 payload
>
> 环境：macOS arm64，Xcode 26.6（17F113），Swift 6.3.3，SDK 26.5，Release 构建

## 1. 运行方式

```bash
swift run --package-path Packages/SingleGreenGlassesKit -c release TeleprompterBenchmark
```

工具输出 versioned JSON。当前覆盖正常逐字、漏字、多字、口头语、10/30/50/51 字跳读、重复短语/句、partial 修订、累计/增量/跨 Session、静默、噪声占位、中英数字混读、20,000 字上限和 30/60 分钟模拟会话。

## 2. 当前基线

| 指标 | 结果 | 口径 |
| --- | ---: | --- |
| 场景数 | 20 | 合成 fixture 分类 |
| 决策次数 | 5,424 | 含 30/60 分钟静默长会话循环 |
| 预期 jump | 3 | 10/30/50 字；51 字预期保持 |
| 实际 jump | 3 | 所有场景合计，与 10/30/50 字预期一致 |
| 误跃迁 | 0 | 实际 jump 但 fixture 不期望 jump |
| 误跃迁率 | 0% | 误跃迁 / 实际 jump；样本很小，不外推真实发生率 |
| 漏跃迁 | 0 | 预期 jump 但实际未 jump |
| 漏跃迁率 | 0% | 漏跃迁 / 预期 jump；样本很小，不外推真实发生率 |
| 平均位置误差 | 0.000369 UTF-16 code unit | 被 5,400 次静默长会话稀释，只用于本次回归对比 |
| 最大位置误差 | 2 UTF-16 code units | partial 修订场景；所有非保持期望均显式提供目标锚点 |
| P50 决策耗时 | 2,209 ns | Release、本机单进程；不等于设备延迟 |
| P95 决策耗时 | 5,542 ns | Release、本机单进程；不等于设备延迟 |
| 进程峰值常驻内存 | 8,388,608 bytes | macOS `getrusage` 进程峰值，不是 Engine 独占增量 |
| 状态更新数 | 18 | 非 stay 且位置发生变化的决策 |
| 每模拟分钟状态更新数 | 0.2 | 18 / 90 分钟；长会话是静默保持，不代表真实朗读频率 |
| 规则类型不一致 | 0 | fixture 期望与实际 `stay / advance / jump` 一致 |

## 3. 需要关注的基线现象

- 10、30、50 字跳读均得到预期 jump；51 字保持，边界符合当前规则。
- 重复短语、重复句、静默、噪声占位和 20,000 字远端后缀均保持当前位置。
- 多字场景不再把任意匹配后缀截成 jump；增量转写的 2–3 个规范化字符只在当前锚点精确连续命中时按普通 `advance` 推进。
- 20 个场景的规则类型全部一致；仅 partial 修订场景保留最大 2 UTF-16 code units 的位置误差。
- 评测器会拒绝“期望 advance/jump 但未给目标锚点”的 fixture，避免把缺省锚点误算为位置误差。
- 相比修复前同一套 fixture，误跃迁由 2 降为 0、规则类型不一致由 4 降为 0、最大位置误差由 10 降为 2；性能数字存在单次本机测量波动。
- 以上结果只用于建立可重复回归起点。没有批准的目标值，因此本批次不据此判定产品达标或不达标。

## 4. 证据边界

- 已证明：合成 fixture 可重复运行，指标结构可编码，报告不携带正文或转写，Release 本机可采集决策耗时与进程峰值内存。
- 当前代码门禁：SingleGreenGlassesKit 273/273、七 Package strict-concurrency/WAE 589/589、架构 inventory 与 16 个负向 fixture 通过；当前 SingleGreenUser App Simulator 96/96（0 failures、0 skips）和 User Release generic Simulator build 通过。
- 公开 API：在锁定 Xcode 26.6 / Swift 6.3.3 上完成差异审阅。提词器保留旧构造与单参数载稿入口；接受 M11 新增持久化 API 和 M12 内部 Target 导致的声明归属变化。更新后 8 个公开模块的 macOS arm64 / iOS Simulator arm64 双架构基线全部通过。
- App 版本：当前源码为 `0.1 (10)`，作为历史内测包 `0.1 (9)` 之后的下一构建号；本记录不声称已生成、签名或安装 Build 10 IPA。
- 未证明：真实普通话、真实 ASR partial 形态、噪声、网络、真机性能、眼镜体验、30/60 分钟真实音频连续性和生产分布。
- 本次没有执行真机 build/install/launch、真实 ASR 或物理眼镜验证；Simulator、Package 与 API 快照不替代这些证据。
