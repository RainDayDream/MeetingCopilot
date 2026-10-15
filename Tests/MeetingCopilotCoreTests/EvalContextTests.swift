import Foundation
import Testing
@testable import MeetingCopilotCore

/// 上下文评测：回放每段对话的自动触发，检查提示词的前缀稳定性、长度、“当前这一轮”是否标对。
struct EvalContextTests {
    static func past(_ p: Prompt) -> String { p.blocks.prefix((p.cacheIdx ?? -1) + 1).joined(separator: "\n\n") }

    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: "[对方]", with: "").replacingOccurrences(of: "[我]", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @Test func contextEval() throws {
        var pairs = 0, stable = 0
        var promptChars: [Int] = []
        var checked = 0, marked = 0
        var unmarked: [String] = []
        for d in try EvalData.loadDialogs() {
            let r = Replay.run(d)
            for i in 1..<max(r.asks.count, 1) where r.asks.count > 1 {
                pairs += 1
                if r.asks[i].prompt.user.hasPrefix(Self.past(r.asks[i - 1].prompt)) { stable += 1 }
            }
            for a in r.asks { promptChars.append(a.prompt.stable.count + a.prompt.user.count) }
            // “当前这一轮”是否完整标出：与应回答的标注对齐的准时触发，其当前轮块必须包含该轮对方说的每一段
            for x in d.expected where x.shouldAnswer {
                guard let a = r.asks.first(where: { $0.time >= x.questionEnd - 1e-9 && $0.time <= x.windowEnd + 1e-9 }) else { continue }
                checked += 1
                let cur = Self.strip(a.prompt.blocks.first { $0.hasPrefix("【当前这一轮") } ?? "")
                if d.questionSegments(x).allSatisfy({ cur.contains(Self.strip($0)) }) { marked += 1 } else { unmarked.append("\(d.id)/\(x.id)") }
            }
        }
        let out: [String: Any] = [
            "prefix_stability": EvalMetrics.rate(stable, pairs) as Any,
            "prefix_pairs": pairs,
            "avg_prompt_chars": promptChars.isEmpty ? 0 : Double(promptChars.reduce(0, +)) / Double(promptChars.count),
            "prompts": promptChars.count,
            "current_question_marked": EvalMetrics.rate(marked, checked) as Any,
            "current_question_checked": checked,
            "current_question_unmarked": unmarked,
        ]
        try EvalData.writePartial("context", out)
    }
}
