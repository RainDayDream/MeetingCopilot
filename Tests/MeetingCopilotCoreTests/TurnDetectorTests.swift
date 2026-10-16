import Foundation
import Testing
@testable import MeetingCopilotCore

struct TurnDetectorTests {
    /// 句末问号：约 0.5 秒触发（从说完的时刻算起，已扣除识别耗时）
    @Test func questionMarkFiresFast() {
        let sim = Sim()
        let t0 = sim.now
        sim.update("对方", "你能介绍一下你的项目吗？")
        sim.advance(by: 3)
        #expect(sim.asks.count == 1)
        #expect(abs(sim.asks[0].time.timeIntervalSince(t0) - 0.5) < 1e-6)
    }

    @Test func sentenceEndWaitsBySensitivity() {
        for (sens, wait) in [(0, 0.8), (1, 1.5), (2, 2.5)] {
            let sim = Sim()
            sim.sensitivity = sens
            let t0 = sim.now
            sim.update("对方", "讲讲你的项目经历。")
            sim.advance(by: 6)
            #expect(sim.asks.count == 1)
            #expect(abs(sim.asks[0].time.timeIntervalSince(t0) - wait) < 1e-6)
        }
    }

    /// 识别耗时已经过去的部分会从等待中扣除
    @Test func asrLatencyIsDeductedFromWait() {
        let sim = Sim()
        let end = sim.now
        sim.advance(by: 1.0)          // 识别花了 1 秒才出结果
        sim.update("对方", "讲讲你的项目经历。", end: end)
        sim.advance(by: 3)
        #expect(abs(sim.asks[0].time.timeIntervalSince(end) - 1.5) < 1e-6)   // 总共 1.5s，而不是 1.0 + 1.5
    }

    /// 句末是逗号/省略号/语气词：对方几乎一定还要接着说，等待明显更长（标准灵敏度 6 秒）
    @Test func hesitationEndingWaitsLong() {
        for text in ["那你在这个项目里，", "我想问的是……", "关于这个方案，嗯", "Let me think, so what I wanted to ask is"] {
            let sim = Sim()
            let t0 = sim.now
            sim.update("对方", text)
            sim.advance(by: 10)
            #expect(sim.asks.count == 1, "\(text)")
            #expect(abs(sim.asks[0].time.timeIntervalSince(t0) - 6.0) < 1e-6, "\(text)")
        }
    }

    /// 没有句末标点（识别没给出标点）：大概率没说完，等待 4.5 秒
    @Test func noTerminalPunctuationWaitsFourPointFive() {
        let sim = Sim()
        let t0 = sim.now
        sim.update("对方", "你能介绍一下你在这个项目里负责的模块")
        sim.advance(by: 10)
        #expect(sim.asks.count == 1)
        #expect(abs(sim.asks[0].time.timeIntervalSince(t0) - 4.5) < 1e-6)
    }

    @Test func tooShortTurnIsIgnored() {
        let sim = Sim()
        sim.update("对方", "好的。")
        sim.advance(by: 5)
        #expect(sim.asks.isEmpty)
    }

    @Test func interviewerResumingCancelsPending() {
        let sim = Sim()
        sim.update("对方", "我们先看一下这个方案。")
        sim.advance(by: 0.8)
        sim.update("对方", "你觉得它的瓶颈在哪里？", final: false)   // 对方又开口了（临时结果）
        sim.advance(by: 5)
        #expect(sim.asks.isEmpty)   // 临时结果没有定稿，不触发
    }

    @Test func meSpeakingCancelsAndSuppresses() {
        let sim = Sim()
        sim.update("对方", "还有什么想补充的吗？")
        sim.advance(by: 0.15)
        sim.update("我", "我觉得基本都讲清楚了，谢谢。")
        sim.advance(by: 5)
        #expect(sim.asks.isEmpty)
    }

    @Test func shortAcknowledgementByMeDoesNotCancel() {
        let sim = Sim()
        sim.update("对方", "你能介绍一下你的项目吗？")
        sim.advance(by: 0.2)
        sim.update("我", "嗯")
        sim.advance(by: 3)
        #expect(sim.asks.count == 1)
    }

    @Test func oneTriggerPerTurnAndManualMarksAnswered() {
        let sim = Sim()
        sim.update("对方", "请讲讲你的项目经历。")
        sim.advance(by: 0.3)
        sim.manualAsk()
        sim.advance(by: 5)
        #expect(sim.asks.count == 1)
        #expect(sim.asks[0].auto == false)
    }

    @Test func disabledNeverFires() {
        let sim = Sim()
        sim.autoEnabled = false
        sim.update("对方", "你能介绍一下你的项目吗？")
        sim.advance(by: 5)
        #expect(sim.asks.isEmpty)
    }

    @Test func minGapBetweenAutoTriggers() {
        let sim = Sim()
        sim.update("对方", "第一个问题是什么？")
        sim.advance(by: 0.6)
        #expect(sim.asks.count == 1)
        sim.update("对方", "第二个问题又是什么？")   // 与上一个同属一轮（我没说话）：这一轮的最后一句换了 → 可再触发，但需间隔 > 1.5s
        sim.advance(by: 0.6)
        #expect(sim.asks.count == 1)   // 距上次 < 1.5s，被拦截
    }

    /// 外放回声：对方的话在“我”通道重复出现，不应被当成我在回应而取消触发
    @Test func echoInMicChannelDoesNotCancel() {
        let sim = Sim()
        sim.update("对方", "你能介绍一下你的项目吗？")
        sim.advance(by: 0.1)
        sim.update("我", "你能介绍一下你的项目吗？")
        sim.advance(by: 3)
        #expect(sim.asks.count == 1)
    }

    /// 我真的在回应（内容与对方的话不同）仍然取消
    @Test func genuineReplyStillCancelsWithEchoGuard() {
        let sim = Sim()
        sim.update("对方", "你能介绍一下你的项目吗？")
        sim.advance(by: 0.1)
        sim.update("我", "可以，我先讲一下整体架构吧。")
        sim.advance(by: 3)
        #expect(sim.asks.isEmpty)
    }

    /// 寒暄/确认/评价/过渡：不触发；带提问或请求线索的仍触发（偏向召回）
    @Test func acknowledgementsDoNotTriggerButRequestsDo() {
        for (text, fires) in [("好的，我们开始吧。", false), ("嗯，你的简历我看过了，整体不错。", false), ("OK, that makes sense, thank you.", false),
                              ("好，那我们进入下一个环节。", false), ("好的，那说说你最大的缺点。", true), ("嗯，你为什么选择我们？", true),
                              ("Thanks. Could you describe your last project?", true), ("讲讲你的项目。", true), ("我们公司主要做推荐系统。", true)] {
            let sim = Sim()
            sim.update("对方", text)
            sim.advance(by: 10)
            #expect((sim.asks.count == 1) == fires, "\(text)")
        }
    }

    /// 前一句是确认语、后一句补上请求：整轮文本带线索，应触发
    @Test func ackFollowedByRequestInSameTurnTriggers() {
        let sim = Sim()
        sim.update("对方", "好的，不错。")
        sim.advance(by: 1.0)
        sim.update("对方", "那请你介绍一下这个项目的架构。")
        sim.advance(by: 10)
        #expect(sim.asks.count == 1)
    }

    // MARK: VAD 语音起始早期信号

    /// 对方重新开口的 VAD 信号立刻取消待触发（不必等识别结果）
    @Test func speechStartCancelsPendingImmediately() {
        let base = Date(timeIntervalSince1970: 1000)
        let d = TurnDetector(clock: { base })
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: base, text: "我们先看一下这个方案。", isFinal: true)
        let a = d.onUpdate(lines: lines, speaker: "对方", text: "我们先看一下这个方案。", isFinal: true, end: base, autoEnabled: true, sensitivity: nil)
        guard case .schedule = a else { Issue.record("应安排触发"); return }
        #expect(d.onSpeechStart(speaker: "对方") == .cancel)
    }

    /// 我的语音起始不影响对方的待触发（麦克风里可能是噪声/回声）
    @Test func myspeechStartIsIgnored() {
        let d = TurnDetector()
        #expect(d.onSpeechStart(speaker: "我") == .none)
    }

    /// 对方的这段声音最终没有文字（噪声）：必须把触发重新安排回来，否则漏答
    @Test func noiseAfterSpeechStartRearmsTrigger() {
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        let d = TurnDetector(clock: { now })
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: base, text: "你能介绍一下你的项目吗？", isFinal: true)
        _ = d.onUpdate(lines: lines, speaker: "对方", text: "你能介绍一下你的项目吗？", isFinal: true, end: base, autoEnabled: true, sensitivity: nil)
        now = base.addingTimeInterval(0.3)
        #expect(d.onSpeechStart(speaker: "对方") == .cancel)
        now = base.addingTimeInterval(1.5)
        let a = d.onEmptyFinal(lines: lines, speaker: "对方", autoEnabled: true, sensitivity: nil)
        guard case .schedule(let delay, _) = a else { Issue.record("没有重新安排"); return }
        #expect(delay > 0 && delay < 0.2)       // 已超过原定等待，几乎立即触发
        // 这一轮已经触发过：再来空结果不重复安排
        if case .schedule(_, let key) = a { #expect(d.shouldFire(key: key, lines: lines)) }
        #expect(d.onEmptyFinal(lines: lines, speaker: "对方", autoEnabled: true, sensitivity: nil) == .none)
    }

    /// 对方说完上一句后很快又开口：VAD 信号早于上一句的识别结果到达，上一句定稿时不能再安排触发
    @Test func speechStartedBeforePreviousFinalSuppressesSchedule() {
        let base = Date(timeIntervalSince1970: 1000)
        var now = base
        let d = TurnDetector(clock: { now })
        var lines: [TranscriptLine] = []
        TranscriptOps.apply(&lines, speaker: "对方", segment: 1, start: base, text: "你能介绍一下你的项目吗？", isFinal: true)
        now = base.addingTimeInterval(1.2)                  // 上一句 0 秒说完，1.0 秒后对方又开口，VAD 信号 1.2 秒到
        #expect(d.onSpeechStart(speaker: "对方") == .cancel)
        now = base.addingTimeInterval(1.5)                  // 上一句的识别结果此时才到
        let a = d.onUpdate(lines: lines, speaker: "对方", text: "你能介绍一下你的项目吗？", isFinal: true, end: base, autoEnabled: true, sensitivity: nil)
        #expect(a == .cancel)
    }

    /// 完整句但没有任何提问/请求线索（多半是铺垫题目背景）：多等 1 秒；有线索的不受影响
    @Test func cueLessStatementWaitsOneExtraSecond() {
        let a = Sim(); let t0 = a.now
        a.update("对方", "假设你要设计一个短链接服务。")
        a.advance(by: 10)
        #expect(abs(a.asks[0].time.timeIntervalSince(t0) - 2.5) < 1e-6)
        let b = Sim(); let t1 = b.now
        b.update("对方", "请你设计一个短链接服务。")
        b.advance(by: 10)
        #expect(abs(b.asks[0].time.timeIntervalSince(t1) - 1.55) < 0.06)
    }
}
