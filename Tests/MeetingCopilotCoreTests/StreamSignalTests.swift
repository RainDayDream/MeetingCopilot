import AVFoundation
import Foundation
import Testing
@testable import MeetingCopilotCore

/// 用真实的合成音频（含键盘噪声）验证 WhisperStream 的早期信号：
///  - 对方通道：语音一开始就通知 onSpeechStart；
///  - 麦克风通道：键盘敲击噪声不会触发 onSpeechSustained，我真正说话约 1 秒后才触发，且每段只触发一次。
/// 不需要 Whisper 模型（识别任务会因模型未加载而返回空结果，不影响信号）。
struct StreamSignalTests {
    final class Marks: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [Double] = [], sustained: [Double] = []
        var fed = 0.0
        func setFed(_ v: Double) { lock.lock(); fed = v; lock.unlock() }
        func addStart() { lock.lock(); starts.append(fed); lock.unlock() }
        func addSustained() { lock.lock(); sustained.append(fed); lock.unlock() }
        func snapshot() -> (starts: [Double], sustained: [Double]) { lock.lock(); defer { lock.unlock() }; return (starts, sustained) }
    }

    static func feed(_ samples: [Float], stream: WhisperStream, marks: Marks, chunk: Int = 1600) async throws {
        var i = 0
        while i < samples.count {
            let j = min(i + chunk, samples.count)
            marks.setFed(Double(j) / 16000)
            stream.append(EvalASRTests.buffer(samples[i..<j]))
            i = j
            try await Task.sleep(nanoseconds: chunk >= 1600 ? 3_000_000 : 600_000)    // 快于实时，给信号回调留出处理时间
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test(arguments: [320, 1600, 4800]) func micSustainedSignalIgnoresKeyboardNoise(chunk: Int) async throws {
        let id = "imperative_01"                              // 右声道带键盘敲击噪声，我在问题之后说“好的，我先从整体说起。”
        let d = try #require(try EvalData.loadDialogs().first { $0.id == id })
        let (_, right) = try EvalASRTests.channels(EvalPaths.audio.appendingPathComponent(id + ".wav"))
        let mine = try #require(d.events.first { $0.speaker == "我" && $0.kind == "speech" })

        let marks = Marks()
        let mic = WhisperStream(speaker: "我", voiceThreshold: 0.02, minSpeech: 0.6, sustainedSecs: 0.5)
        mic.onSpeechStart = { marks.addStart() }
        mic.onSpeechSustained = { marks.addSustained() }
        mic.start()
        // 采集缓冲区大小不同（20 ms / 100 ms / 300 ms）结果都必须一样：键盘噪声不触发，我说话才触发
        try await Self.feed(right, stream: mic, marks: marks, chunk: chunk)
        mic.stop()
        let m = marks.snapshot()
        // 只在我真正说话之后触发一次，且在说话开始 0.7 秒之后（0.8 秒有声）
        #expect(m.sustained.count == 1, "chunk=\(chunk) 持续有声信号次数 \(m.sustained)（我开口 \(mine.start)s）")
        if let t = m.sustained.first {
            print("[stream-signal] chunk=\(chunk): 持续有声信号在我开口后 \(String(format: "%.2f", t - mine.start)) 秒（我开口 \(mine.start)s）")
            #expect(t >= mine.start + 0.6 && t <= mine.start + 1.6, "信号时刻 \(t)，我开口 \(mine.start)")
        }
    }

    @Test func systemSpeechStartFiresAtTheStartOfEachSegment() async throws {
        let id = "multi_question_01"
        let d = try #require(try EvalData.loadDialogs().first { $0.id == id })
        let (left, _) = try EvalASRTests.channels(EvalPaths.audio.appendingPathComponent(id + ".wav"))
        let theirs = d.events.filter { $0.speaker == "对方" && $0.kind == "speech" }

        let marks = Marks()
        let sys = WhisperStream(speaker: "对方")
        sys.onSpeechStart = { marks.addStart() }
        sys.start()
        try await Self.feed(left, stream: sys, marks: marks)
        sys.stop()
        let starts = marks.snapshot().starts
        #expect(starts.count == theirs.count, "起始信号 \(starts)，对方各段开始 \(theirs.map(\.start))")
        for (t, e) in zip(starts, theirs) { #expect(t >= e.start && t <= e.start + 0.5, "信号 \(t) 对应段开始 \(e.start)") }
    }
}
