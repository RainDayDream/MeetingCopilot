import Foundation

public struct CurrentTurn {
    public let text: String
    public let lastID: UUID
    public let lastTime: Date
}

/// 把对话记录切成“轮”：同一说话人连续的话为一轮；其他说话人夹杂的附和（“嗯”“对”“Right.”）并入当前轮；
/// 外放回声（“我”通道里重复出现的对方的话）不参与切分，也不出现在提示词里。
public enum TurnSplitter {
    /// 单纯的附和/应答，不构成一轮话。注意：不能按长度判断，否则“为什么？”这样的短问题会被并进我的回答里，永远触发不了。
    public static func isBackchannel(_ text: String) -> Bool {
        let t = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        if t.isEmpty { return true }
        let words: Set<String> = ["yeah", "yes", "yep", "right", "ok", "okay", "sure", "mhm", "hmm", "uh", "um", "uhhuh", "igotit", "isee", "gotit",
                                  "好的", "好", "是的", "是", "对的", "对", "行", "可以", "明白", "了解", "哈哈", "哈哈哈", "呵呵", "嗯好的", "好的好的", "对对对", "是是是"]
        if words.contains(t) { return true }
        let chars = Set("嗯哦噢啊呃额唔哎")
        return t.count <= 4 && t.allSatisfy { chars.contains($0) }
    }

    /// 去掉外放回声：“我”的话如果几乎是附近对方说过的话的重复，就丢掉
    public static func cleaned(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        lines.filter { !($0.speaker == "我" && EchoGuard.isEcho($0.text, lines: lines, reference: $0.time)) }
    }

    public struct Block {
        public var speaker: String
        public var idx: [Int]
    }

    public static func blocks(_ input: [TranscriptLine]) -> [Block] {
        let lines = input
        var out: [Block] = []
        for (i, l) in lines.enumerated() {
            if let last = out.last, last.speaker == l.speaker || isBackchannel(l.text) {
                out[out.count - 1].idx.append(i)
            } else {
                out.append(Block(speaker: l.speaker, idx: [i]))
            }
        }
        return out
    }

    /// 对方最近一轮连续发言（只取对方自己的话）
    public static func currentTurn(_ input: [TranscriptLine]) -> CurrentTurn? {
        // 每来一次转写更新都要算一次：只看最近的若干句即可（对话再长也是常数开销）；最近没有对方的话时才回退到全量
        let recent = Array(input.suffix(80))
        if recent.count < input.count, recent.contains(where: { $0.speaker == "对方" }) {
            let lines = cleaned(recent)
            if let t = turn(in: lines) { return t }
        }
        return turn(in: cleaned(input))
    }

    private static func turn(in lines: [TranscriptLine]) -> CurrentTurn? {
        guard let b = blocks(lines).last(where: { $0.speaker == "对方" }) else { return nil }
        let theirs = b.idx.map { lines[$0] }.filter { $0.speaker == "对方" }
        guard let last = theirs.last else { return nil }
        return CurrentTurn(text: theirs.map(\.text).joined(separator: " "), lastID: last.id, lastTime: last.time)
    }
}
