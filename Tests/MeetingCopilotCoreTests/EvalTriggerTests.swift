import Foundation
import Testing
@testable import MeetingCopilotCore

/// 触发评测：把 59 段标注对话按识别时序回放给 TurnDetector，统计抢答/漏答/误答/延迟/重复触发。
/// 不做断言（指标只是被记录；是否达标见 eval/thresholds.json 与 ISSUES.md）。
struct EvalTriggerTests {
    static func summarize(_ s: EvalMetrics.TriggerStats) -> [String: Any] {
        var o: [String: Any] = ["should_answer": s.shouldAnswer, "non_questions": s.nonQuestions, "premature": s.premature,
                                "miss": s.miss, "false_answer": s.falseAnswer, "duplicate_triggers": s.duplicates,
                                "stray_triggers": s.stray, "total_triggers": s.total]
        if let r = EvalMetrics.rate(s.premature, s.shouldAnswer) { o["premature_rate"] = r }
        if let r = EvalMetrics.rate(s.miss, s.shouldAnswer) { o["miss_rate"] = r }
        if let r = EvalMetrics.rate(s.falseAnswer, s.nonQuestions) { o["false_answer_rate"] = r }
        if let p = EvalMetrics.percentile(s.latencies, 0.5) { o["latency_p50_s"] = p }
        if let p = EvalMetrics.percentile(s.latencies, 0.95) { o["latency_p95_s"] = p }
        o["latency_samples"] = s.latencies.count
        return o
    }

    @Test func triggerEval() throws {
        let dialogs = try EvalData.loadDialogs()
        func run(_ sens: Int?) -> (EvalMetrics.TriggerStats, [String: EvalMetrics.TriggerStats], [String: Any]) {
            var all = EvalMetrics.TriggerStats()
            var byCat: [String: EvalMetrics.TriggerStats] = [:]
            var perDialog: [String: Any] = [:]
            for d in dialogs {
                let r = Replay.run(d, sensitivity: sens)
                let s = EvalMetrics.scoreTriggers(r.triggers, d.expected)
                all.add(s); byCat[d.category, default: EvalMetrics.TriggerStats()].add(s)
                perDialog[d.id] = ["triggers": r.triggers.map { ($0 * 1000).rounded() / 1000 },
                                   "premature": s.premature, "miss": s.miss, "false_answer": s.falseAnswer,
                                   "duplicates": s.duplicates, "stray": s.stray]
            }
            return (all, byCat, perDialog)
        }
        let (all, byCat, perDialog) = run(nil)
        var out = Self.summarize(all)
        out["by_category"] = Dictionary(uniqueKeysWithValues: byCat.map { ($0.key, Self.summarize($0.value)) })
        out["per_dialog"] = perDialog
        // 灵敏度对比（仅供参考，主指标是默认灵敏度 1）
        out["sensitivity_sweep"] = Dictionary(uniqueKeysWithValues: [0, 2].map { (s: Int) in ("\(s)", Self.summarize(run(s).0)) })
        out["asr_timing_model"] = ["vad_silence_s": ASRTiming.vadSilence, "asr_latency_s": ASRTiming.asrLatency,
                                   "partial_interval_s": ASRTiming.partialInterval, "mic_min_speech_s": ASRTiming.micMinSpeech,
                                   "sys_min_speech_s": ASRTiming.sysMinSpeech]
        try EvalData.writePartial("trigger", out)
        #expect(all.shouldAnswer + all.nonQuestions == dialogs.reduce(0) { $0 + $1.expected.count })
    }
}
