import AVFoundation
import Foundation
import Testing
@testable import MeetingCopilotCore

/// ASR 评测：把 10 段双通道 wav（左=对方，右=我）按产品方式送入两路 WhisperStream，度量识别错误率、
/// 麦克风通道的幻觉句数和回声泄漏。需要本地 Whisper 模型（首次会下载到 eval/.cache，之后离线）。
/// 环境变量：EVAL_ASR=0 跳过；EVAL_ASR_MODEL 指定模型（默认 small，与产品默认一致）。
struct EvalASRTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: [Int: SegmentUpdate] = [:]
        func put(_ u: SegmentUpdate) { lock.lock(); latest[u.id] = u; lock.unlock() }
        func finals() -> [SegmentUpdate] {
            lock.lock(); defer { lock.unlock() }
            return latest.values.filter(\.isFinal).sorted { $0.start < $1.start }
        }
    }

    static func channels(_ url: URL) throws -> ([Float], [Float]) {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        let d = buf.floatChannelData!
        return (Array(UnsafeBufferPointer(start: d[0], count: n)), Array(UnsafeBufferPointer(start: d[1], count: n)))
    }

    static func buffer(_ s: ArraySlice<Float>) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        b.frameLength = AVAudioFrameCount(s.count)
        for (i, v) in s.enumerated() { b.floatChannelData![0][i] = v }
        return b
    }

    @Test func asrEval() async throws {
        let env = ProcessInfo.processInfo.environment
        if env["EVAL_ASR"] == "0" { try EvalData.writePartial("asr", ["status": "skipped", "reason": "EVAL_ASR=0"]); return }
        let model = env["EVAL_ASR_MODEL"] ?? "small"
        do {
            try await WhisperEngine.shared.load(model: model, baseDirectory: EvalPaths.cache.appendingPathComponent("models")) { print("[asr] \($0)") }
        } catch {
            try EvalData.writePartial("asr", ["status": "skipped", "reason": "模型不可用（首次需要联网下载）：\(error.localizedDescription)"])
            return
        }
        await WhisperEngine.shared.setLanguage(nil)
        let manifest = try EvalData.loadManifest()
        let dialogs = Dictionary(uniqueKeysWithValues: try EvalData.loadDialogs().map { ($0.id, $0) })

        var zh = (e: 0, t: 0), en = (e: 0, t: 0), mixed = (e: 0, t: 0), me = (e: 0, t: 0)
        var halluAll = 0, halluNoise = 0, echoLeaked = 0, echoTotal = 0
        var clips: [String: Any] = [:]
        var latencies: [Double] = []

        for (id, clip) in manifest.sorted(by: { $0.key < $1.key }) {
            let (left, right) = try Self.channels(EvalPaths.audio.appendingPathComponent(clip.file))
            let sys = WhisperStream(speaker: "对方")
            let mic = WhisperStream(speaker: "我", voiceThreshold: 0.02, minSpeech: 0.6)
            let sysBox = Box(), micBox = Box()
            sys.onUpdate = { sysBox.put($0) }; mic.onUpdate = { micBox.put($0) }
            sys.start(); mic.start()
            var i = 0
            while i < left.count {
                let j = min(i + 1600, left.count)
                sys.append(Self.buffer(left[i..<j])); mic.append(Self.buffer(right[i..<j]))
                i = j
            }
            sys.stop(); mic.stop()
            try await Task.sleep(nanoseconds: 400_000_000)
            await sys.waitIdle(); await mic.waitIdle()

            let sysHyp = sysBox.finals().map(\.text).joined()
            let micLines = micBox.finals().map(\.text)
            let refSys = clip.reference["对方"] ?? "", refMe = clip.reference["我"] ?? ""
            let d = dialogs[id]!
            if d.lang == "en" { let r = EvalMetrics.wer(ref: refSys, hyp: sysHyp); en.e += r.errors; en.t += r.total }
            else if d.lang == "mixed" { let r = EvalMetrics.cer(ref: refSys, hyp: sysHyp); mixed.e += r.errors; mixed.t += r.total }
            else { let r = EvalMetrics.cer(ref: refSys, hyp: sysHyp); zh.e += r.errors; zh.t += r.total }
            // 我通道：真实语音 / 回声 / 幻觉
            var real = 0, echo = 0, hallu = 0
            for l in micLines {
                if EvalMetrics.overlap(l, refMe) >= 0.5 { real += 1 }
                else if EvalMetrics.overlap(l, refSys) >= 0.5 { echo += 1 }
                else { hallu += 1 }
            }
            halluAll += hallu; if clip.micNoise { halluNoise += hallu }
            let meHyp = micLines.joined()
            let rm = EvalMetrics.cer(ref: refMe, hyp: meHyp); me.e += rm.errors; me.t += rm.total
            if clip.echo {
                for e in d.events where e.speaker == "对方" && e.kind == "speech" {
                    echoTotal += 1
                    if EvalMetrics.overlap(e.text, meHyp) >= 0.5 { echoLeaked += 1 }
                }
            }
            // 识别延迟：对方每一段单独识别的耗时
            for e in d.events where e.speaker == "对方" && e.kind == "speech" {
                let a = max(0, Int((e.start - 0.2) * 16000)), b = min(left.count, Int((e.end + 0.2) * 16000))
                let t0 = Date()
                _ = try await WhisperEngine.shared.transcribe(Array(left[a..<b]))
                latencies.append(Date().timeIntervalSince(t0))
            }
            clips[id] = ["lang": d.lang, "ref_sys": refSys, "hyp_sys": sysHyp, "ref_me": refMe, "mic_lines": micLines,
                         "mic_real": real, "mic_echo_like": echo, "mic_hallucination": hallu, "mic_noise": clip.micNoise, "echo_clip": clip.echo]
        }
        func rate(_ x: (e: Int, t: Int)) -> Any { x.t == 0 ? NSNull() : Double(x.e) / Double(x.t) }
        var out: [String: Any] = [
            "status": "ok", "model": model,
            "cer_zh": rate(zh), "cer_zh_chars": zh.t,
            "wer_en": rate(en), "wer_en_words": en.t,
            "cer_mixed": rate(mixed), "cer_mixed_chars": mixed.t,
            "cer_me_channel": rate(me),
            "mic_hallucination_lines": halluAll, "mic_hallucination_lines_noise_clips": halluNoise,
            "echo_leak_rate": echoTotal == 0 ? NSNull() : Double(echoLeaked) / Double(echoTotal), "echo_segments": echoTotal,
            "clips": clips,
        ]
        if let p = EvalMetrics.percentile(latencies, 0.5) { out["transcribe_latency_p50_s"] = p }
        if let p = EvalMetrics.percentile(latencies, 0.95) { out["transcribe_latency_p95_s"] = p }
        try EvalData.writePartial("asr", out)
    }
}
