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
    /// 最近一次 VAD 检测到对方开始出现语音的时刻，以及最近一个定稿句子的说完时刻
    private var lastSpeechStart: Date?
    private var lastEnd: Date?

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
            lastEnd = end
            // 这句话说完之后，VAD 已经检测到对方又开口了（识别结果比 VAD 晚到 1.5 秒以上）：这一轮还没说完，先不触发，
            // 等新这段话的识别结果（或确认它只是噪声）再判断
            if let s = lastSpeechStart, s > end { return .cancel }
            return schedule(lines: lines, end: end, sensitivity: sensitivity)
        }
        // 我开口回应（一段超过 6 个字的话）→ 取消；但外放回声（对方刚说过的话在我的通道重复出现）不算
        return text.count >= 6 && !EchoGuard.isEcho(text, lines: lines, now: clock()) ? .cancel : .none
    }

    /// VAD 检测到某一路开始出现语音（早于识别结果 2 秒以上）。对方重新开口 → 立刻取消待触发。
    /// 之后如果这段声音最终没有产生文字（噪声、过短），必须调用 `onEmptyFinal` 把触发重新安排回来，否则会漏答。
    public func onSpeechStart(speaker: String) -> Action {
        guard speaker == "对方" else { return .none }
        lastSpeechStart = clock()
        return .cancel
    }

    /// 对方的一段语音结束但没有产生文字（噪声/过短/被幻觉过滤）：这一轮若还没触发过，按最近一个定稿句子的说完时刻重新安排。
    public func onEmptyFinal(lines: [TranscriptLine], speaker: String, autoEnabled: Bool, sensitivity: Int?) -> Action {
        guard speaker == "对方", autoEnabled, let end = lastEnd,
              let turn = TurnSplitter.currentTurn(lines), turn.lastID != lastAutoKey else { return .none }
        return schedule(lines: lines, end: end, sensitivity: sensitivity)
    }

    /// 以“说完的时刻”为起点等待一小段静音：句末有问号 → 很快触发；句号等完整句 → 按灵敏度等待；
    /// 句子没结束（逗号、半句）→ 多等 1 秒，避免对方只是在停顿思考时就被抢答。
    private func schedule(lines: [TranscriptLine], end: Date, sensitivity: Int?) -> Action {
        guard let turn = TurnSplitter.currentTurn(lines), turn.text.count >= 4, let last = turn.text.last else { return .cancel }
        // 寒暄、确认、评价、过渡语（且没有提问/请求的线索）：不需要回答，不触发模型调用
        guard ResponseCue.needsResponse(turn.text) else { return .cancel }
        let base = [0.8, 1.5, 2.5][min(max(sensitivity ?? 1, 0), 2)]
        let wait: Double
        switch Ending.classify(turn.text) {
        case .question: wait = min(0.5, base)
        case .sentence: wait = base
        // 句末是逗号/省略号/语气词/连接词：对方几乎一定还要接着说。识别结果最晚要在对方重新开口 2.7 秒后才到达，
        // 所以等待必须明显更长，才有机会在触发前收到“对方又开口了”的信号
        case .hesitation: wait = base + 4.5
        case .open: wait = base + 3.0      // 没有句末标点，大概率没说完
        }
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
        let now = clock()
        if let mine = lines.last(where: { $0.speaker == "我" && $0.text.count >= 6 && !EchoGuard.isEcho($0.text, lines: lines, now: now) }),
           mine.time >= turn.lastTime { return false }
        lastAutoKey = key
        lastAuto = clock()
        return true
    }

    /// 手动触发：把当前这一轮标记为已回答，避免随后又自动重复触发
    public func markManual(lines: [TranscriptLine]) {
        if let t = TurnSplitter.currentTurn(lines) { lastAutoKey = t.lastID }
    }

    public func reset() { lastAutoKey = nil; lastSpeechStart = nil; lastEnd = nil }
}

/// 外放时，对方的话会被麦克风重新收进“我”的通道。用字符二元组重合度判断一句“我”的话是不是对方刚说过的话。
public enum EchoGuard {
    static func bigrams(_ s: String) -> Set<String> {
        let c = Array(s.lowercased()).filter { $0.isLetter || $0.isNumber }
        guard c.count >= 2 else { return Set(c.map { String($0) }) }
        return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }

    /// text 的二元组至少 60% 出现在最近 20 秒内对方说过的话里 → 视为回声
    public static func isEcho(_ text: String, lines: [TranscriptLine], now: Date) -> Bool {
        let mine = bigrams(text)
        guard mine.count >= 3 else { return false }
        var theirs = Set<String>()
        for l in lines where l.speaker == "对方" && now.timeIntervalSince(l.time) < 20 { theirs.formUnion(bigrams(l.text)) }
        guard !theirs.isEmpty else { return false }
        return Double(mine.filter { theirs.contains($0) }.count) / Double(mine.count) >= 0.6
    }
}

/// 一轮话的句末类型，决定触发前等多久
enum Ending {
    case question, sentence, hesitation, open

    static func classify(_ text: String) -> Ending {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return .open }
        if "?？".contains(last) { return .question }
        if "，,、—…:：;；".contains(last) || t.hasSuffix("...") { return .hesitation }
        let lower = t.lowercased()
        let fillers = ["嗯", "呃", "啊", "额", "那个", "这个", "就是", "然后", "所以", "因为", "但是", "如果", "或者", "以及", "并且", "还有",
                       "让我想想", "我想问的是", "我想了解一下", "的", "是", "um", "uh", "so", "and", "but", "or", "because", "the", "a",
                       "to", "of", "that", "is", "um,", "wanted to ask is"]
        if !"。.！!".contains(last) {
            if fillers.contains(where: { lower.hasSuffix($0) }) { return .hesitation }
            return .open
        }
        return .sentence
    }
}

/// 这一轮话是否需要“我”回应。偏向召回：只有明确是寒暄/确认/评价/过渡、并且没有任何提问或请求线索时，才判定不需要。
enum ResponseCue {
    static let cues: [String] = [
        "?", "？", "吗", "什么", "怎么", "为什么", "为何", "如何", "哪", "多少", "几个", "谁", "是否", "能不能", "可不可以", "能否", "会不会",
        "请你", "请问", "请讲", "请说", "请介绍", "请描述", "讲讲", "说说", "谈谈", "聊聊你", "介绍", "描述", "解释", "分析", "举例", "举个",
        "说一下", "讲一下", "谈一下", "给我们讲", "告诉我", "想问", "想了解", "你觉得", "你认为", "你会", "有没有", "你有什么",
        "what", "how", "why", "when", "where", "which", "who ", "could you", "can you", "would you", "do you", "did you", "have you",
        "tell me", "walk me", "describe", "explain", "talk about", "please", "let me know", "any question", "your thoughts",
    ]
    static let ackStarts: [String] = [
        "好的", "好，", "好。", "嗯", "不错", "行，", "对，", "对。", "明白", "了解", "清楚", "谢谢", "感谢", "辛苦", "你好", "您好", "欢迎",
        "ok", "okay", "great", "good", "nice", "thanks", "thank you", "i see", "alright", "got it", "right,", "interesting", "hi", "hello", "welcome",
    ]
    static let transitions: [String] = ["进入下一", "下一个环节", "下一个问题", "今天就到这里", "就到这里", "我们开始", "开始吧", "that's all", "that is all", "let's move on", "moving on"]

    static func needsResponse(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cues.contains(where: { t.contains($0) }) { return true }
        let ack = ackStarts.contains(where: { t.hasPrefix($0) }) || transitions.contains(where: { t.contains($0) })
        return !ack
    }
}
