import Foundation
import Testing
@testable import MeetingCopilotCore

/// 重构前后行为一致的证明：在虚拟时间里回放 AppModel 的 `--selftest-context` 场景，
/// 与重构前（提交 53b26f9）用同一场景在真实二进制上记录的基线逐项对比。
///
/// 重构前基线（mock 服务器记录）：
///   - 5 个请求；用户消息字数 [249, 415, 537, 642, 584]；
///   - 相邻前缀关系 [无, 断开（第一次时对话为空）, 一致, 一致, 一致]；
///   - 触发延迟（相对上一个事件）≈ [0.5, 0.5, 0.5, 0.5, 0.1] 秒；
///   - “对方刚问完我立刻开口”不触发；自动回答开着时手动触发只产生 1 次调用。
/// 另外，重构前后真实二进制发出的每个请求的完整消息体 md5 逐一相同（记录在 LOG.md）。
struct EquivalenceTests {
    static let preset = "对方刚刚提出了问题或观点。先用一句话概括对方在问什么，然后给出我可以直接说出口的回答（3-5 个要点），必要时附一个简短例子。"

    @Test func selftestContextScenarioMatchesBaseline() {
        let sim = Sim(presetPrompt: Self.preset, background: "岗位：机器学习工程师")
        var delays: [Double] = []

        for i in 1...3 {
            let t0 = sim.now
            sim.update("对方", "第\(i)个问题：请介绍一下你在项目里用到的技术方案与取舍？")
            sim.advance(to: t0.addingTimeInterval(2.5))
            delays.append(sim.asks.last!.time.timeIntervalSince(t0))
            sim.update("我", "第\(i)个回答：我们采用了双塔召回加重排的方案并做了离线评估。")
            sim.advance(by: 0.8)
        }
        // T2：对方刚问完，我立刻开口 → 不触发
        let n2 = sim.asks.count
        sim.update("对方", "还有什么想补充的吗？")
        sim.advance(by: 0.15)
        sim.update("我", "我觉得基本都讲清楚了，谢谢您的提问。")
        sim.advance(by: 2.5)
        #expect(sim.asks.count == n2)
        // T3：半句停顿后继续说完 → 只在说完后触发一次
        sim.update("对方", "那你在这个项目里，")
        sim.advance(by: 1.2)
        #expect(sim.asks.count == n2)
        let t3 = sim.now
        sim.update("对方", "具体负责了哪一部分？")
        sim.advance(by: 3.0)
        #expect(sim.asks.count == n2 + 1)
        delays.append(sim.asks.last!.time.timeIntervalSince(t3))
        // T4：自动回答开着，对方刚问完立刻手动触发 → 只有 1 次调用（手动）
        sim.advance(by: 1.5)
        let n4 = sim.asks.count
        let t4 = sim.now
        sim.update("对方", "请再详细说明一下这个取舍的依据？")
        sim.advance(by: 0.1)
        sim.manualAsk()
        delays.append(sim.asks.last!.time.timeIntervalSince(t4))
        sim.advance(by: 3.0)
        #expect(sim.asks.count == n4 + 1)

        #expect(sim.asks.count == 5)
        #expect(sim.asks.map(\.auto) == [true, true, true, true, false])
        for d in delays.prefix(4) { #expect(abs(d - 0.5) < 1e-6) }
        #expect(abs(delays[4] - 0.1) < 1e-6)

        // 用户消息字数与基线一致
        #expect(sim.asks.map { $0.prompt.user.count } == [249, 415, 537, 642, 584])

        // 相邻前缀：上一个请求“当前这一轮”之前的部分必须是下一个请求的前缀（第一次对话为空，基线中断开）
        let marker = "\n\n【当前这一轮"
        var flags: [String] = ["n/a"]
        for i in 1..<sim.asks.count {
            let prev = sim.asks[i - 1].prompt.user.components(separatedBy: marker)[0]
            flags.append(sim.asks[i].prompt.user.hasPrefix(prev) ? "OK" : "BROKEN")
        }
        #expect(flags == ["n/a", "BROKEN", "OK", "OK", "OK"])
    }
}
