import Foundation

/// 自动回答：判断“对方这一轮是否说完”并决定何时触发。纯逻辑，不含定时器和 UI；时钟可注入，便于回放评测。
///
/// 用法：每收到一次转写更新（已应用到 lines 之后）调用 `onUpdate`，按返回的动作取消/安排定时器；
/// 定时器到点后调用 `shouldFire`，返回 true 才真正触发。手动触发时调用 `markManual`。
public final class TurnDetector {
    public enum Action: Equatable {
        case none
        /// 取消已安排的触发
        case cancel
        /// 取消已安排的触发，并在 delay 秒后检查 key 对应的这一轮
        case schedule(delay: TimeInterval, key: UUID)
    }

    public var clock: () -> Date
    private var lastAuto = Date.distantPast
    private var lastAutoKey: UUID?

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// - Parameters:
    ///   - lines: 已应用本次更新的对话记录
    ///   - end: 这段话实际说完的时刻（定稿时已扣除末尾静音）
    ///   - autoEnabled: 自动回答已开启且正在监听
    ///   - sensitivity: 0 灵敏 / 1 标准 / 2 稳妥
    public func onUpdate(lines: [TranscriptLine], speaker: String, text: String, isFinal: Bool,
                         end: Date, autoEnabled: Bool, sensitivity: Int?) -> Action {
        if speaker == "对方" {
            // 对方还在说 → 取消等待；一句话定稿 → 判断这一轮是否说完
            guard isFinal, autoEnabled else { return .cancel }
            return schedule(lines: lines, end: end, sensitivity: sensitivity)
        }
        // 我开口回应（一段超过 6 个字的话）→ 取消
        return text.count >= 6 ? .cancel : .none
    }

    /// 以“说完的时刻”为起点等待一小段静音：句末有问号 → 很快触发；句号等完整句 → 按灵敏度等待；
    /// 句子没结束（逗号、半句）→ 多等 1 秒，避免对方只是在停顿思考时就被抢答。
    private func schedule(lines: [TranscriptLine], end: Date, sensitivity: Int?) -> Action {
        guard let turn = TurnSplitter.currentTurn(lines), turn.text.count >= 4, let last = turn.text.last else { return .cancel }
        let base = [0.8, 1.5, 2.5][min(max(sensitivity ?? 1, 0), 2)]
        let wait: Double
        if "?？".contains(last) { wait = min(0.5, base) }
        else if "。.！!…".contains(last) { wait = base }
        else { wait = base + 1.0 }
        // 语音识别本身已耗时，从实际说完的时刻算起
        let delay = max(0.05, wait - clock().timeIntervalSince(end))
        return .schedule(delay: delay, key: turn.lastID)
    }

    /// 定时器到点：检查是否应该触发。返回 true 时已记录“这一轮已触发”。
    public func shouldFire(key: UUID, lines: [TranscriptLine]) -> Bool {
        guard let turn = TurnSplitter.currentTurn(lines), turn.lastID == key, lastAutoKey != key,
              !lines.contains(where: { $0.speaker == "对方" && $0.isPartial }),
              clock().timeIntervalSince(lastAuto) > 1.5 else { return false }
        // 我已经开始回应了：不打扰
        if let mine = lines.last(where: { $0.speaker == "我" && $0.text.count >= 6 }), mine.time >= turn.lastTime { return false }
        lastAutoKey = key
        lastAuto = clock()
        return true
    }

    /// 手动触发：把当前这一轮标记为已回答，避免随后又自动重复触发
    public func markManual(lines: [TranscriptLine]) {
        if let t = TurnSplitter.currentTurn(lines) { lastAutoKey = t.lastID }
    }

    public func reset() { lastAutoKey = nil }
}
