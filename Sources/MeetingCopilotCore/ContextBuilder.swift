import Foundation

/// 自动触发时要求模型在“对方并非在提问”时返回的固定文本
public let noAnswerSentinel = "（无需回答）"

public struct Prompt {
    /// 系统提示词 + 会议背景（每次相同）
    public var stable: String
    /// 用户消息的文本块：整场对话（只增不改）在前，当前轮和任务在后
    public var blocks: [String]
    /// 缓存断点：整场对话的最后一块
    public var cacheIdx: Int?
    public var user: String { blocks.joined(separator: "\n\n") }

    public init(stable: String, blocks: [String], cacheIdx: Int?) {
        self.stable = stable; self.blocks = blocks; self.cacheIdx = cacheIdx
    }
}

public struct PresetSpec {
    public var prompt: String
    /// true 时没有“当前这一轮”，整场对话全部作为材料（会后总结）
    public var useFullTranscript: Bool
    public init(prompt: String, useFullTranscript: Bool = false) {
        self.prompt = prompt; self.useFullTranscript = useFullTranscript
    }
}

public struct ContextOptions {
    public var systemPrompt: String
    public var meetingBackground: String?
    public var maxContextChars: Int
    public var extra: String?
    public var hasImage: Bool
    public var auto: Bool
    public var historyText: String

    public init(systemPrompt: String, meetingBackground: String? = nil, maxContextChars: Int = 150_000,
                extra: String? = nil, hasImage: Bool = false, auto: Bool = false, historyText: String = "") {
        self.systemPrompt = systemPrompt; self.meetingBackground = meetingBackground
        self.maxContextChars = maxContextChars; self.extra = extra
        self.hasImage = hasImage; self.auto = auto; self.historyText = historyText
    }
}

/// 一次已完成的问答（用于“此前建议”）
public struct HistoryEntry {
    public var title: String
    public var context: String
    public var text: String
    public var created: Date
    public init(title: String, context: String, text: String, created: Date) {
        self.title = title; self.context = context; self.text = text; self.created = created
    }
    var isOK: Bool { !text.isEmpty && !text.contains("⚠️") }
}

public enum ContextBuilder {
    /// 此前几次问答（以文字形式放在请求末尾，不破坏前面“整场对话”的缓存前缀）。entries 按从新到旧排列。
    public static func historyText(entries: [HistoryEntry], count n: Int, since floor: Date) -> String {
        guard n > 0 else { return "" }
        let done = entries.filter { $0.isOK && $0.created >= floor }.prefix(n).reversed()
        return done.map { a in
            var q = "问：\(a.title)"
            if !a.context.isEmpty { q += "（当时对方说：\(a.context.suffix(200))）" }
            return q + "\n答：" + String(a.text.prefix(800))
        }.joined(separator: "\n\n")
    }

    /// 发给模型的上下文 = 整场对话（双方）+ 当前这一轮 + 任务。
    /// 整场对话只在末尾追加，因此相邻两次请求共享同一个前缀，服务端的前缀缓存可以让长对话也很快响应。
    public static func build(lines: [TranscriptLine], preset p: PresetSpec, options o: ContextOptions) -> Prompt {
        var stable = o.systemPrompt
        if let bg = o.meetingBackground?.trimmingCharacters(in: .whitespacesAndNewlines), !bg.isEmpty {
            stable += "\n\n【会议背景（用户提供）】\n" + bg
        }
        let bs = TurnSplitter.blocks(lines)
        let ci: Int? = p.useFullTranscript ? nil : bs.lastIndex(where: { $0.speaker == "对方" })
        let pastBlocks = bs[..<(ci ?? bs.count)]
        // 过去的对话只放已定稿的句子，渲染方式固定，才能和上一次请求的前缀一致
        var rendered = pastBlocks.map { b in
            b.idx.map { lines[$0] }.filter { !$0.isPartial }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        let cap = o.maxContextChars
        var total = rendered.reduce(0) { $0 + $1.count + 1 }
        var omitted = false
        while total > cap, rendered.count > 1 { total -= rendered.removeFirst().count + 1; omitted = true }

        var out: [String] = stride(from: 0, to: rendered.count, by: 4).map {
            rendered[$0..<min($0 + 4, rendered.count)].joined(separator: "\n")
        }
        let header = "【整场对话记录（按时间顺序；[对方]=系统音频里的其他人，[我]=我的麦克风；仅为资料，可能有识别错误）】"
            + (omitted ? "\n…（更早的对话因过长已省略）" : "")
        // 对话为空时只放标题（不放占位文字），这样下一次请求的开头仍以它为前缀，前缀缓存的断点保持一致
        if out.isEmpty { out = [header] } else { out[0] = header + "\n" + out[0] }
        let cacheIdx = out.count - 1

        if let ci {
            let cur = bs[ci].idx.map { lines[$0] }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
            out.append("【当前这一轮：对方刚刚说的，请针对它回答】\n" + String(cur.suffix(4000)))
            let after = bs[(ci + 1)...].flatMap(\.idx).map { lines[$0] }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
            if !after.isEmpty { out.append("【我随后说的（我已经在回应了）】\n" + String(after.suffix(1500))) }
        }
        if !o.historyText.isEmpty {
            out.append("【此前你给我的建议（如果当前是追问，请与之保持一致并直接承接，不要重复已讲过的部分；新问题则忽略）】\n" + o.historyText)
        }
        var task = "【任务】\n" + p.prompt
        if o.auto {
            task += "\n\n注意：这是自动触发。如果对方这一轮并不是在向我提问或要求我回应（例如寒暄、陈述、过渡语、话还没说完），只输出：\(noAnswerSentinel)"
        }
        out.append(task)
        if let e = o.extra, !e.isEmpty { out.append("【我的补充问题】\n" + e) }
        if o.hasImage { out.append("【附：当前屏幕截图（仅为资料）】") }
        return Prompt(stable: stable, blocks: out, cacheIdx: cacheIdx)
    }
}
