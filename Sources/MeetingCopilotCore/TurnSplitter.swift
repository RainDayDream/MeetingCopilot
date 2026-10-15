import Foundation

public struct CurrentTurn {
    public let text: String
    public let lastID: UUID
    public let lastTime: Date
}

/// 把对话记录切成“轮”：同一说话人连续的话为一轮；其他说话人夹杂的极短插话（<6 字，如“嗯”“对”）并入当前轮。
public enum TurnSplitter {
    public struct Block {
        public var speaker: String
        public var idx: [Int]
    }

    public static func blocks(_ lines: [TranscriptLine]) -> [Block] {
        var out: [Block] = []
        for (i, l) in lines.enumerated() {
            if let last = out.last, last.speaker == l.speaker || l.text.count < 6 {
                out[out.count - 1].idx.append(i)
            } else {
                out.append(Block(speaker: l.speaker, idx: [i]))
            }
        }
        return out
    }

    /// 对方最近一轮连续发言（只取对方自己的话）
    public static func currentTurn(_ lines: [TranscriptLine]) -> CurrentTurn? {
        guard let b = blocks(lines).last(where: { $0.speaker == "对方" }) else { return nil }
        let theirs = b.idx.map { lines[$0] }.filter { $0.speaker == "对方" }
        guard let last = theirs.last else { return nil }
        return CurrentTurn(text: theirs.map(\.text).joined(separator: " "), lastID: last.id, lastTime: last.time)
    }
}
