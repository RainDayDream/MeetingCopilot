import Foundation
import Testing
@testable import MeetingCopilotCore

/// 扩展评测（不在冻结范围内，不影响 scripts/eval.sh 的正式指标）：
/// 冻结的评测时序模型里，“对方又开口了”的信息只能来自识别结果（开口后 ≥ 2.7 秒才到）。
/// 产品现在多了一个更早的信号：WhisperStream 的 VAD 一检测到声音就通知（`onSpeechStart`）。
/// 这里用同样的数据集和同样的指标函数，在回放里额外加入这个信号，度量它带来的变化。
/// 结果写到 eval/results/.partial/trigger_early.json，并打印摘要。
struct EvalEarlySignalTests {
    static let vadLatency = 0.2   // 一个音频块 + 切句余量

    static let meSustainedSecs = 0.8

    enum Item { case upd(Upd), start(Double), empty(Double), me(Double) }

    final class EarlySim {
        var now: Date
        var lines: [TranscriptLine] = []
        let detector: TurnDetector
        private var pending: (fireAt: Date, key: UUID)?
        var triggers: [Date] = []

        init(start: Date) {
            now = start
            var clock: () -> Date = { Date() }
            detector = TurnDetector(clock: { clock() })
            clock = { [unowned self] in self.now }
        }

        func apply(_ a: TurnDetector.Action) {
            switch a {
            case .none: break
            case .cancel: pending = nil
            case .schedule(let d, let k): pending = (now.addingTimeInterval(d), k)
            }
        }

        func advance(to t: Date) {
            while let p = pending, p.fireAt <= t {
                now = max(now, p.fireAt)
                pending = nil
                if detector.shouldFire(key: p.key, lines: lines) { triggers.append(now) }
            }
            if t > now { now = t }
        }

        func update(_ u: Upd, base: Date) {
            let ok = TranscriptOps.apply(&lines, speaker: u.speaker, segment: u.segment, start: base.addingTimeInterval(u.start),
                                         text: u.text, isFinal: u.isFinal)
            guard ok else { return }
            apply(detector.onUpdate(lines: lines, speaker: u.speaker, text: u.text, isFinal: u.isFinal,
                                    end: base.addingTimeInterval(u.end), autoEnabled: true, sensitivity: nil))
        }
    }

    static func run(_ d: EvalDialog, meSignal: Bool) -> [Double] {
        var items: [(Double, Int, Item)] = []
        var seq = 0
        func add(_ t: Double, _ i: Item) { seq += 1; items.append((t, seq, i)) }
        for u in Replay.updates(for: d) { add(u.arrival, .upd(u)) }
        for e in d.events where e.speaker == "对方" {
            add(e.start + vadLatency, .start(e.start))
            let dropped = (e.end - e.start) < ASRTiming.sysMinSpeech || WhisperEngine.clean(e.text).isEmpty
            if dropped { add(e.end + ASRTiming.vadSilence, .empty(e.end)) }
        }
        if meSignal {
            // 麦克风通道（含最坏情况下被识别的外放回声）持续有声 0.8 秒时通知；systemSilentFor = 对方那一路已安静多久
            for e in d.events where e.speaker == "我" && (e.end - e.start) >= meSustainedSecs {
                let t = e.start + meSustainedSecs + 0.1
                var silent = Double.infinity
                for o in d.events where o.speaker == "对方" && o.kind == "speech" && o.start <= t {
                    silent = min(silent, o.end >= t ? 0 : t - o.end)
                }
                add(t, .me(silent))
            }
        }
        items.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        let base = Date(timeIntervalSince1970: 2_000_000)
        let sim = EarlySim(start: base)
        for (t, _, item) in items {
            sim.advance(to: base.addingTimeInterval(t))
            switch item {
            case .upd(let u): sim.update(u, base: base)
            case .start: sim.apply(sim.detector.onSpeechStart(speaker: "对方"))
            case .empty: sim.apply(sim.detector.onEmptyFinal(lines: sim.lines, speaker: "对方", autoEnabled: true, sensitivity: nil))
            case .me(let silent): sim.apply(sim.detector.onMeSpeaking(systemSilentFor: silent))
            }
        }
        sim.advance(to: base.addingTimeInterval((items.last?.0 ?? 0) + 15))
        return sim.triggers.map { $0.timeIntervalSince(base) }
    }

    @Test func earlySignalEval() throws {
        var results: [String: Any] = [:]
        for (name, me) in [("vad_start", false), ("vad_start_plus_me_speaking", true)] {
            var all = EvalMetrics.TriggerStats()
            var byCat: [String: EvalMetrics.TriggerStats] = [:]
            for d in try EvalData.loadDialogs() {
                let s = EvalMetrics.scoreTriggers(Self.run(d, meSignal: me), d.expected)
                all.add(s); byCat[d.category, default: EvalMetrics.TriggerStats()].add(s)
            }
            var out = EvalTriggerTests.summarize(all)
            out["by_category"] = Dictionary(uniqueKeysWithValues: byCat.map { ($0.key, EvalTriggerTests.summarize($0.value)) })
            results[name] = out
            func p(_ k: String) -> String { (out[k] as? Double).map { String(format: "%.1f%%", $0 * 100) } ?? "-" }
            print("[early-signal] \(name): 抢答 \(p("premature_rate"))  漏答 \(p("miss_rate"))  误答 \(p("false_answer_rate"))  重复 \(all.duplicates)  P95 \(String(format: "%.2f", out["latency_p95_s"] as? Double ?? 0))")
            for (c, v) in byCat.sorted(by: { $0.key < $1.key }) where ["me_interrupt", "echo", "chitchat"].contains(c) {
                print("[early-signal]   \(c): 抢答 \(v.premature)/\(v.shouldAnswer) 漏答 \(v.miss)/\(v.shouldAnswer) 误答 \(v.falseAnswer)/\(v.nonQuestions)")
            }
        }
        results["note"] = "扩展回放：VAD 语音起始信号（延迟 0.2s）；再加“我持续有声 0.8s”信号。正式指标仍以冻结评测为准"
        try EvalData.writePartial("trigger_early", results)
    }
}
