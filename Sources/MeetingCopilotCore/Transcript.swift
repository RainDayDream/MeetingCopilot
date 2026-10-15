import Foundation

/// 对话记录中的一行（一句话）。
public struct TranscriptLine: Identifiable {
    public let id: UUID
    public let speaker: String
    public let segment: Int
    public var text: String
    public var isPartial: Bool
    public let time: Date

    public init(id: UUID = UUID(), speaker: String, segment: Int, text: String, isPartial: Bool, time: Date) {
        self.id = id; self.speaker = speaker; self.segment = segment
        self.text = text; self.isPartial = isPartial; self.time = time
    }
}

public enum TranscriptOps {
    /// 把一次转写更新应用到对话记录：同一说话人的同一段话更新原行，否则按开始时间插入；
    /// 空文本的定稿会移除对应的临时行。返回 false 表示这是一次空更新（调用方不应继续做触发判断）。
    @discardableResult
    public static func apply(_ lines: inout [TranscriptLine], speaker: String, segment: Int,
                             start: Date, text raw: String, isFinal: Bool) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx = lines.firstIndex { $0.speaker == speaker && $0.segment == segment }
        if text.isEmpty {
            if isFinal, let i = idx { lines.remove(at: i) }
            return false
        }
        if let i = idx {
            lines[i].text = text
            lines[i].isPartial = !isFinal
        } else {
            let line = TranscriptLine(speaker: speaker, segment: segment, text: text, isPartial: !isFinal, time: start)
            let at = lines.lastIndex { $0.time <= start }.map { $0 + 1 } ?? 0
            lines.insert(line, at: at)
        }
        return true
    }
}
