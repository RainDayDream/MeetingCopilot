import Foundation

enum EvalMetrics {
    // MARK: 触发
    struct TriggerStats {
        var shouldAnswer = 0, nonQuestions = 0
        var premature = 0, miss = 0, falseAnswer = 0
        var duplicates = 0, stray = 0, total = 0
        var latencies: [Double] = []
        mutating func add(_ o: TriggerStats) {
            shouldAnswer += o.shouldAnswer; nonQuestions += o.nonQuestions; premature += o.premature; miss += o.miss
            falseAnswer += o.falseAnswer; duplicates += o.duplicates; stray += o.stray; total += o.total
            latencies += o.latencies
        }
    }

    /// 触发时刻与标注对齐。每条标注有窗口 [turn_start, window_end]：
    ///  - 应回答：窗口内 question_end 之前的触发 = 抢答；question_end 及之后的第一次触发 = 准时（记延迟）；没有 → 漏答
    ///  - 不应回答：窗口内任何触发 = 误答
    ///  - 窗口内多于 1 次触发的部分 = 重复触发；不在任何窗口内的触发 = 游离触发
    static func scoreTriggers(_ triggers: [Double], _ expected: [EvalExpect]) -> TriggerStats {
        var s = TriggerStats()
        s.total = triggers.count
        var used = Set<Int>()
        for x in expected {
            let inWin = triggers.enumerated().filter { $0.element >= x.turnStart - 1e-9 && $0.element <= x.windowEnd + 1e-9 }
            inWin.forEach { used.insert($0.offset) }
            let ts = inWin.map(\.element)
            s.duplicates += max(0, ts.count - 1)
            if x.shouldAnswer {
                s.shouldAnswer += 1
                if ts.contains(where: { $0 < x.questionEnd - 1e-9 }) { s.premature += 1 }
                if let first = ts.first(where: { $0 >= x.questionEnd - 1e-9 }) { s.latencies.append(first - x.questionEnd) } else { s.miss += 1 }
            } else {
                s.nonQuestions += 1
                if !ts.isEmpty { s.falseAnswer += 1 }
            }
        }
        s.stray = triggers.count - used.count
        return s
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let idx = Int((p * Double(s.count - 1)).rounded(.up))
        return s[min(max(idx, 0), s.count - 1)]
    }

    static func rate(_ a: Int, _ b: Int) -> Double? { b == 0 ? nil : Double(a) / Double(b) }

    // MARK: 文本距离
    static func normalizeChars(_ s: String) -> [Character] {
        Array(s.lowercased()).filter { $0.isLetter || $0.isNumber }
    }

    static func normalizeWords(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    static func cer(ref: String, hyp: String) -> (errors: Int, total: Int) {
        let r = normalizeChars(ref), h = normalizeChars(hyp)
        return (editDistance(r, h), r.count)
    }

    static func wer(ref: String, hyp: String) -> (errors: Int, total: Int) {
        let r = normalizeWords(ref), h = normalizeWords(hyp)
        return (editDistance(r, h), r.count)
    }

    /// 字符二元组集合，用于判断一句话是否“像”某段参考文本
    static func bigrams(_ s: String) -> Set<String> {
        let c = normalizeChars(s)
        guard c.count >= 2 else { return Set(c.map { String($0) }) }
        return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }

    static func overlap(_ line: String, _ reference: String) -> Double {
        let a = bigrams(line)
        guard !a.isEmpty else { return 0 }
        let b = bigrams(reference)
        return Double(a.filter { b.contains($0) }.count) / Double(a.count)
    }
}
