import Foundation
@testable import MeetingCopilotCore

/// 虚拟时间的“会话模拟器”：用与 AppModel 相同的 TranscriptOps / TurnDetector / ContextBuilder 回放事件，
/// 不用真实定时器，时钟可控，结果确定。
final class Sim {
    var now: Date
    var lines: [TranscriptLine] = []
    let detector: TurnDetector
    var autoEnabled = true
    var sensitivity: Int? = nil
    private var seg = 0
    private var pending: (fireAt: Date, key: UUID)?

    struct Ask {
        let time: Date
        let auto: Bool
        let prompt: Prompt
    }
    var asks: [Ask] = []
    var history: [HistoryEntry] = []   // 新 → 旧

    let systemPrompt: String
    let presetPrompt: String
    var background: String?
    var historyCount = 2

    init(start: Date = Date(timeIntervalSince1970: 1_000_000), systemPrompt: String = "SYS", presetPrompt: String = "TASK",
         background: String? = nil) {
        now = start
        self.systemPrompt = systemPrompt; self.presetPrompt = presetPrompt; self.background = background
        var clock: () -> Date = { Date() }
        detector = TurnDetector(clock: { clock() })
        clock = { [unowned self] in self.now }
    }

    /// 推进虚拟时间到 t，期间到点的自动触发会被检查
    func advance(to t: Date) {
        while let p = pending, p.fireAt <= t {
            now = max(now, p.fireAt)
            pending = nil
            if autoEnabled, detector.shouldFire(key: p.key, lines: lines) { ask(auto: true) }
        }
        if t > now { now = t }
    }
    func advance(by dt: TimeInterval) { advance(to: now.addingTimeInterval(dt)) }

    /// 一句转写更新（与 AppModel.handle 相同的流程）。end 默认为当前时刻。
    func update(_ speaker: String, _ text: String, final: Bool = true, segment: Int? = nil, start: Date? = nil, end: Date? = nil) {
        let id = segment ?? { seg += 1; return seg }()
        guard TranscriptOps.apply(&lines, speaker: speaker, segment: id, start: start ?? now, text: text, isFinal: final) else { return }
        let a = detector.onUpdate(lines: lines, speaker: speaker, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  isFinal: final, end: end ?? now, autoEnabled: autoEnabled, sensitivity: sensitivity)
        switch a {
        case .none: break
        case .cancel: pending = nil
        case .schedule(let delay, let key): pending = (now.addingTimeInterval(delay), key)
        }
    }

    func manualAsk() {
        pending = nil
        detector.markManual(lines: lines)
        ask(auto: false)
    }

    func ask(auto: Bool) {
        let h = ContextBuilder.historyText(entries: history, count: historyCount, since: .distantPast)
        let p = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: presetPrompt),
                                     options: ContextOptions(systemPrompt: systemPrompt, meetingBackground: background,
                                                             auto: auto, historyText: h))
        asks.append(Ask(time: now, auto: auto, prompt: p))
        history.insert(HistoryEntry(title: (auto ? "自动 · " : "") + "实时回答",
                                    context: lines.last { $0.speaker == "对方" }?.text ?? "", text: "建议回答", created: now), at: 0)
    }
}
