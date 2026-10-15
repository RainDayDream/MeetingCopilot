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

    @Test func midSentenceWaitsExtraSecond() {
        let sim = Sim()
        let t0 = sim.now
        sim.update("对方", "那你在这个项目里，")
        sim.advance(by: 5)
        #expect(sim.asks.count == 1)
        #expect(abs(sim.asks[0].time.timeIntervalSince(t0) - 2.5) < 1e-6)
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
}
