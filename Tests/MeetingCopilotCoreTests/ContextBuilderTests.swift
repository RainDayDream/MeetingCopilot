import Foundation
import Testing
@testable import MeetingCopilotCore

struct ContextBuilderTests {
    @Test func currentTurnIsMarkedAndComplete() {
        let sim = Sim()
        sim.update("对方", "你好，请先做个自我介绍。")
        sim.advance(by: 3)
        sim.update("我", "您好，我叫小明，做推荐系统方向。")
        sim.advance(by: 3)
        sim.update("对方", "好的。那说说你最有挑战的项目，")
        sim.advance(by: 1)
        sim.update("对方", "当时遇到了什么困难？")
        sim.advance(by: 3)
        let p = sim.asks.last!.prompt
        let cur = p.blocks.first { $0.hasPrefix("【当前这一轮") }
        #expect(cur != nil)
        #expect(cur!.contains("说说你最有挑战的项目"))
        #expect(cur!.contains("当时遇到了什么困难？"))
        #expect(!cur!.contains("自我介绍"))                       // 上一轮不在“当前这一轮”里
        #expect(p.blocks[p.cacheIdx!].contains("自我介绍") || p.blocks.joined().contains("自我介绍"))  // 但在整场记录里
    }

    @Test func fullTranscriptPresetHasNoCurrentTurn() {
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: Date(), text: "问题一？", isFinal: true)
        TranscriptOps.apply(&lines, speaker: "我", segment: 2, start: Date().addingTimeInterval(1), text: "回答一，内容比较长。", isFinal: true)
        let p = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: "总结", useFullTranscript: true),
                                     options: ContextOptions(systemPrompt: "S"))
        #expect(!p.user.contains("【当前这一轮"))
        #expect(p.user.contains("[对方] 问题一？") && p.user.contains("[我] 回答一，内容比较长。"))
    }

    @Test func partialLinesAreExcludedFromPast() {
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: Date(), text: "第一个问题？", isFinal: true)
        TranscriptOps.apply(&lines, speaker: "我", segment: 2, start: Date().addingTimeInterval(1), text: "正在说的话还没有结束", isFinal: false)
        TranscriptOps.apply(&lines, speaker: "对方", segment: 3, start: Date().addingTimeInterval(2), text: "第二个问题？", isFinal: true)
        let p = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: "T"), options: ContextOptions(systemPrompt: "S"))
        #expect(!p.blocks[p.cacheIdx!].contains("正在说的话"))
    }

    @Test func prefixStableAcrossGrowingConversation() {
        let sim = Sim()
        for i in 1...8 {
            sim.update("对方", "第\(i)个问题是什么呢？")
            sim.advance(by: 2)
            sim.update("我", "第\(i)个回答，我是这样做的，先分析再实现。")
            sim.advance(by: 2)
        }
        func past(_ p: Prompt) -> String { p.blocks.prefix((p.cacheIdx ?? -1) + 1).joined(separator: "\n\n") }
        #expect(sim.asks.count == 8)
        for i in 2..<sim.asks.count {
            #expect(sim.asks[i].prompt.user.hasPrefix(past(sim.asks[i - 1].prompt)), "第 \(i) 个请求的前缀应包含上一个请求的整场对话")
        }
        #expect(Set(sim.asks.map(\.prompt.stable)).count == 1)   // 系统提示词/背景每次相同
    }

    @Test func overlongConversationDropsOldestAndSaysSo() {
        var lines: [TranscriptLine] = []
        for i in 0..<60 {
            // 双方内容明显不同（否则“我”的话会被当作外放回声过滤掉）
            let text = i % 2 == 0 ? String(repeating: "请说明方案\(i)的取舍与风险。", count: 8)
                                  : String(repeating: "我的回答\(i)是先分析需求再拆分模块。", count: 8)
            TranscriptOps.apply(&lines, speaker: i % 2 == 0 ? "对方" : "我", segment: i,
                                start: Date(timeIntervalSince1970: Double(i)), text: text, isFinal: true)
        }
        let p = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: "T"),
                                     options: ContextOptions(systemPrompt: "S", maxContextChars: 800))
        #expect(p.user.contains("更早的对话因过长已省略"))
        #expect(!p.user.contains("我的回答1是"))
    }

    /// 外放回声（“我”通道里重复出现的对方的话）不进入提示词，也不会把对方的一轮话切断
    @Test func echoLinesAreExcludedAndDoNotSplitTheTurn() {
        let sim = Sim()
        sim.update("对方", "你在团队里遇到过冲突吗？")
        sim.update("我", "你在团队里遇到过冲突吗？")          // 回声
        sim.advance(by: 0.2)
        sim.update("对方", "是怎么处理的？")
        sim.update("我", "是怎么处理的？")                     // 回声
        sim.advance(by: 5)
        let p = sim.asks.last!.prompt
        let cur = p.blocks.first { $0.hasPrefix("【当前这一轮") } ?? ""
        #expect(cur.contains("遇到过冲突") && cur.contains("是怎么处理的"))
        #expect(!p.user.contains("[我] "))      // 回声不出现在提示词里（标题里的“[我]=…”图例不算）
    }

    /// 短问题（“为什么？”）是一轮新的话，不能被当成附和并进我的回答里
    @Test func shortQuestionIsNotSwallowedAsBackchannel() {
        let sim = Sim()
        sim.update("对方", "你是怎么设计这个缓存的？")
        sim.advance(by: 3)
        sim.update("我", "我用了本地缓存加分布式缓存的两级结构。")
        sim.advance(by: 3)
        let n = sim.asks.count
        sim.update("对方", "为什么？")
        sim.advance(by: 5)
        #expect(sim.asks.count == n + 1)
        let cur = sim.asks.last!.prompt.blocks.first { $0.hasPrefix("【当前这一轮") } ?? ""
        #expect(cur.contains("为什么？") && !cur.contains("缓存的？"))
    }

    @Test func backchannelClassification() {
        for t in ["嗯", "嗯嗯。", "对。", "好的", "Right.", "yeah", "Uh-huh", "I see."] { #expect(TurnSplitter.isBackchannel(t), "\(t)") }
        for t in ["为什么？", "嗯，那如果", "数据量再大十倍呢？", "How so?", "Why not Pulsar?"] { #expect(!TurnSplitter.isBackchannel(t), "\(t)") }
    }

    @Test func autoTaskCarriesNoAnswerInstruction() {
        let lines: [TranscriptLine] = []
        let auto = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: "T"), options: ContextOptions(systemPrompt: "S", auto: true))
        let manual = ContextBuilder.build(lines: lines, preset: PresetSpec(prompt: "T"), options: ContextOptions(systemPrompt: "S", auto: false))
        #expect(auto.user.contains(noAnswerSentinel))
        #expect(!manual.user.contains(noAnswerSentinel))
    }

    @Test func turnSplitterMergesShortInterjections() {
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: Date(timeIntervalSince1970: 1), text: "我们来聊聊这个方案的取舍。", isFinal: true)
        TranscriptOps.apply(&lines, speaker: "我", segment: 2, start: Date(timeIntervalSince1970: 2), text: "嗯", isFinal: true)
        TranscriptOps.apply(&lines, speaker: "对方", segment: 3, start: Date(timeIntervalSince1970: 3), text: "你为什么选择了第二种？", isFinal: true)
        let turn = TurnSplitter.currentTurn(lines)
        #expect(turn?.text == "我们来聊聊这个方案的取舍。 你为什么选择了第二种？")
    }
}
