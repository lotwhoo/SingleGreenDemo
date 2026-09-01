import Foundation
import SingleGreenGlassesKit

public enum TeleprompterSyntheticFixtureCatalog {
    public static func makeScenarios() -> [TeleprompterEvaluationScenario] {
        let launch = "欢迎来到产品发布会。今天我们介绍新款单绿眼镜。"
        let launchEnd = ReadingPositionAnchor(sentenceIndex: 1, utf16Offset: 0)
        let jumpSource = "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰菜重芥姜海咸河淡鳞潜羽翔"

        return [
            scenario("normal", "正常逐字", launch, "欢迎来到产品发布会", .advance, launchEnd),
            scenario("omission", "漏字", launch, "欢迎来到产品发会", .advance, launchEnd),
            scenario("insertion", "多字", launch, "欢迎大家来到产品发布会", .advance, launchEnd),
            scenario("filler", "口头语", launch, "嗯欢迎来到产品发布会", .advance, launchEnd),
            jumpScenario(id: "jump-10", distance: 10, source: jumpSource, expected: .jump),
            jumpScenario(id: "jump-30", distance: 30, source: jumpSource, expected: .jump),
            jumpScenario(id: "jump-50", distance: 50, source: jumpSource, expected: .jump),
            jumpScenario(id: "jump-51", distance: 51, source: jumpSource, expected: .stay),
            scenario(
                "repeated-phrase",
                "重复短语",
                "开始重复片段然后继续重复片段最后结束。",
                "重复片段",
                .stay,
                .init(sentenceIndex: 0, utf16Offset: 0)
            ),
            scenario(
                "repeated-sentence",
                "重复句",
                "相同句子。相同句子。最后结束。",
                "相同句子",
                .stay,
                .init(sentenceIndex: 0, utf16Offset: 0)
            ),
            TeleprompterEvaluationScenario(
                id: "partial-revision",
                category: "partial 修订",
                scriptSource: "项目今天正式发布。下一步进入演示。",
                events: [
                    .init(
                        transcriptFragment: "项目今天正式发",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 7)
                    ),
                    .init(
                        transcriptFragment: "项目今天正式发布",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 1, utf16Offset: 0)
                    )
                ]
            ),
            TeleprompterEvaluationScenario(
                id: "cumulative-transcript",
                category: "累计转写",
                scriptSource: "今天我们发布新品。随后进行功能演示。",
                events: [
                    .init(
                        transcriptFragment: "今天",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 2)
                    ),
                    .init(
                        transcriptFragment: "今天我们",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 4)
                    ),
                    .init(
                        transcriptFragment: "今天我们发布新品",
                        semantics: .final,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 1, utf16Offset: 0)
                    )
                ]
            ),
            TeleprompterEvaluationScenario(
                id: "incremental-transcript",
                category: "增量转写",
                scriptSource: "今天我们发布新品。随后进行功能演示。",
                events: [
                    .init(
                        transcriptFragment: "今天",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 2)
                    ),
                    .init(
                        transcriptFragment: "我们",
                        semantics: .partial,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 0, utf16Offset: 4)
                    ),
                    .init(
                        transcriptFragment: "发布新品",
                        semantics: .final,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 1, utf16Offset: 0)
                    )
                ]
            ),
            TeleprompterEvaluationScenario(
                id: "cross-session",
                category: "跨 Session",
                scriptSource: "第一阶段已经完成。第二阶段现在开始。",
                events: [
                    .init(
                        transcriptFragment: "第一阶段已经完成",
                        semantics: .final,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 1, utf16Offset: 0)
                    ),
                    .init(
                        transcriptFragment: "第二阶段现在开始",
                        semantics: .final,
                        expectedDecision: .advance,
                        expectedTarget: .init(sentenceIndex: 1, utf16Offset: 9),
                        resetsSessionStability: true
                    )
                ]
            ),
            scenario("silence", "静默", "请保持当前位置。", "", .stay, nil),
            scenario("noise-placeholder", "噪声占位", "请保持当前位置。", "[noise]", .stay, nil),
            scenario(
                "mixed-language-number",
                "中英数字混读",
                "AI眼镜2026正式发布。谢谢大家。",
                "AI眼镜2026正式发布",
                .advance,
                .init(sentenceIndex: 1, utf16Offset: 0)
            ),
            TeleprompterEvaluationScenario(
                id: "maximum-script",
                category: "20,000 字上限",
                scriptSource: String(repeating: "甲", count: 19_995) + "乙丙丁戊。",
                events: [
                    .init(
                        transcriptFragment: "乙丙丁戊",
                        semantics: .final,
                        expectedDecision: .stay
                    )
                ]
            ),
            TeleprompterEvaluationScenario(
                id: "long-session-30m",
                category: "30 分钟模拟会话",
                scriptSource: "长会话保持当前位置。",
                events: [
                    .init(transcriptFragment: "", semantics: .partial, expectedDecision: .stay)
                ],
                repetitions: 1_800,
                simulatedDurationSeconds: 1_800
            ),
            TeleprompterEvaluationScenario(
                id: "long-session-60m",
                category: "60 分钟模拟会话",
                scriptSource: "长会话保持当前位置。",
                events: [
                    .init(transcriptFragment: "", semantics: .partial, expectedDecision: .stay)
                ],
                repetitions: 3_600,
                simulatedDurationSeconds: 3_600
            )
        ]
    }

    private static func scenario(
        _ id: String,
        _ category: String,
        _ script: String,
        _ transcript: String,
        _ expected: TeleprompterExpectedDecision,
        _ target: ReadingPositionAnchor?
    ) -> TeleprompterEvaluationScenario {
        TeleprompterEvaluationScenario(
            id: id,
            category: category,
            scriptSource: script,
            events: [
                .init(
                    transcriptFragment: transcript,
                    semantics: .final,
                    expectedDecision: expected,
                    expectedTarget: target
                )
            ]
        )
    }

    private static func jumpScenario(
        id: String,
        distance: Int,
        source: String,
        expected: TeleprompterExpectedDecision
    ) -> TeleprompterEvaluationScenario {
        let characters = Array(source)
        let probeEnd = min(distance + 4, characters.count)
        let probe = String(characters[distance..<probeEnd])
        let target = expected == .jump
            ? ReadingPositionAnchor(sentenceIndex: 0, utf16Offset: probeEnd)
            : ReadingPositionAnchor(sentenceIndex: 0, utf16Offset: 0)
        return scenario(id, "\(distance) 字跳读", source + "。", probe, expected, target)
    }
}
