import Foundation
import Testing
@testable import MeetingCopilotCore

/// 回答质量评测的第一步：为 eval/quality/cases.json 里的 10 个固定问题，按“面试官刚问完”的时刻组装产品提示词，
/// 写到 eval/results/.partial/quality_prompts.json。后续由 scripts/eval_quality.py 调用模型并评分（默认关闭，需要 API Key）。
struct EvalQualityPromptsTests {
    struct Case: Decodable { let id: String; let dialog: String; let entry: String }

    @Test func exportPrompts() throws {
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: EvalPaths.eval.appendingPathComponent("quality/cases.json")))
        let dialogs = Dictionary(uniqueKeysWithValues: try EvalData.loadDialogs().map { ($0.id, $0) })
        var out: [[String: Any]] = []
        for c in cases {
            let d = try #require(dialogs[c.dialog])
            let x = try #require(d.expected.first { $0.id == c.entry })
            // 截止到问题说完的时刻：之前所有已说完的段（双方）
            var lines: [TranscriptLine] = []
            for (i, e) in d.events.enumerated() where e.end <= x.questionEnd + 1e-6 && e.kind == "speech" {
                TranscriptOps.apply(&lines, speaker: e.speaker, segment: i + 1, start: Date(timeIntervalSince1970: 3_000_000 + e.start),
                                    text: e.text, isFinal: true)
            }
            let p = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: Replay.presetPrompt),
                                         options: ContextOptions(systemPrompt: Replay.systemPrompt))
            out.append(["id": c.id, "dialog": c.dialog, "entry": c.entry, "question": d.questionSegments(x).joined(),
                        "system": p.stable, "user": p.user])
        }
        try EvalData.writePartial("quality_prompts", out)
        #expect(out.count == cases.count)
    }
}
