import AVFoundation
import Foundation
import WhisperKit

/// 一次转写产生的更新。同一段话的 partial/final 共用 id；start 用于跨来源排序。
public struct SegmentUpdate {
    public let id: Int
    public let start: Date
    public let text: String
    public let isFinal: Bool
    /// 这段话实际说完的时刻（定稿时已扣除末尾静音），用于判断对方是否已经说完
    public var end = Date()

    public init(id: Int, start: Date, text: String, isFinal: Bool, end: Date = Date()) {
        self.id = id; self.start = start; self.text = text; self.isFinal = isFinal; self.end = end
    }
}

/// 本地 Whisper 引擎（WhisperKit / CoreML）。多语言，自动检测语言，支持中英混杂；音频不出本机。
/// 两路音频共用一个模型，调用在 actor 内串行。
public actor WhisperEngine {
    public static let shared = WhisperEngine()
    public init() {}
    private var kit: WhisperKit?
    private var loadedModel: String?
    private var language: String?   // nil = 自动检测

    public struct EngineError: LocalizedError { public let errorDescription: String? }

    public func setLanguage(_ l: String?) { language = l }
    public var isLoaded: Bool { kit != nil }

    /// baseDirectory 默认是应用支持目录下的 MeetingCopilot/models；评测/测试可指定其他目录。
    public func load(model: String, baseDirectory: URL? = nil, onStatus: @escaping @Sendable (String) -> Void) async throws {
        if kit != nil && loadedModel == model { return }
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingCopilot/models", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // 本地已有完整模型就不联网：WhisperKit.download 每次都会先访问网络校验，离线时会失败，界面也会一直显示“下载”
        let folder: URL
        if let local = Self.localModelFolder(base: base, variant: model) {
            folder = local
            onStatus("加载本地识别模型…")
        } else {
            onStatus("下载识别模型 \(model)…（首次需要，请保持联网）")
            folder = try await WhisperKit.download(variant: model, downloadBase: base) { p in
                onStatus("下载识别模型 \(Int(p.fractionCompleted * 100))%")
            }
            onStatus("加载识别模型…（首次约需 1–2 分钟优化）")
        }
        kit = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, modelFolder: folder.path,
                                                    verbose: false, logLevel: .error,
                                                    prewarm: true, load: true, download: false))
        loadedModel = model
    }

    /// 在 models/argmaxinc/whisperkit-coreml/ 下找已下载完整的模型目录（名称以 variant 结尾）
    private static func localModelFolder(base: URL, variant: String) -> URL? {
        let root = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        let wanted = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        for n in names where n == variant || n.hasSuffix("_" + variant) || n.hasSuffix("-" + variant) {
            let dir = root.appendingPathComponent(n, isDirectory: true)
            let ok = wanted.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0 + "/coremldata.bin").path)
            }
            if ok { return dir }
        }
        return nil
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw EngineError(errorDescription: "识别模型尚未加载") }
        // 自动模式只在中文/英文之间选择：避免噪声（键盘声等）被检测成日语、僧伽罗语等并产生乱码
        var lang = language
        if lang == nil {
            let (top, probs) = try await kit.detectLangauge(audioArray: samples)
            let z = probs["zh"] ?? -Float.infinity, e = probs["en"] ?? -Float.infinity
            if top != "zh", top != "en", (probs[top] ?? 0) > 0.6, probs.values.allSatisfy({ $0 >= 0 && $0 <= 1 }) {
                return "" // 非中英文且很确定 → 当作噪声
            }
            lang = z > e ? "zh" : "en"
        }
        var o = DecodingOptions()
        o.task = .transcribe
        o.language = lang
        o.detectLanguage = false
        o.temperature = 0
        o.skipSpecialTokens = true
        o.withoutTimestamps = true
        o.noSpeechThreshold = 0.6
        o.compressionRatioThreshold = 2.4
        let r: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: o)
        var text = r.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if lang == "zh" {
            // Whisper 的中文输出常带繁体，统一转为简体
            text = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
        return Self.clean(text)
    }

    /// 过滤 Whisper 在非语音声音上的“幻觉”：(keyboard clacking)、[tapping]、(laughs)、Thank you. 等
    public static func clean(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉括号里的音效标注
        s = s.replacingOccurrences(of: "[\\(\\[（【][^\\)\\]）】]*[\\)\\]）】]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        let phantoms: Set<String> = ["thank you", "thanks", "thanks for watching", "thank you for watching", "bye", "you",
                                     "谢谢", "谢谢观看", "谢谢大家", "字幕由amara.org社区提供"]
        if phantoms.contains(lower) { return "" }
        // 没有任何字母/汉字（只剩标点）
        if s.unicodeScalars.allSatisfy({ !CharacterSet.letters.contains($0) }) { return "" }
        return s
    }
}

/// 把任意格式的 PCM 转成 16kHz 单声道 Float
public final class Resampler {
    public init() {}
    private static let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var conv: AVAudioConverter?
    private var inFmt: AVAudioFormat?

    public func samples(_ b: AVAudioPCMBuffer) -> [Float] {
        if b.format.sampleRate == 16000, b.format.channelCount == 1, let d = b.floatChannelData {
            return Array(UnsafeBufferPointer(start: d[0], count: Int(b.frameLength)))
        }
        if conv == nil || inFmt != b.format {
            conv = AVAudioConverter(from: b.format, to: Self.out); inFmt = b.format
        }
        let cap = AVAudioFrameCount(Double(b.frameLength) * 16000 / b.format.sampleRate) + 32
        guard let conv, let ob = AVAudioPCMBuffer(pcmFormat: Self.out, frameCapacity: cap) else { return [] }
        var given = false
        var err: NSError?
        conv.convert(to: ob, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true; st.pointee = .haveData; return b
        }
        guard err == nil, let d = ob.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(ob.frameLength)))
    }
}

/// 一路音频的流式转写：能量 VAD 切句 → 说话中每 2 秒出一次临时结果 → 停顿 0.8 秒后出定稿。
public final class WhisperStream {
    public let speaker: String
    public var onUpdate: ((SegmentUpdate) -> Void)?
    public var onError: ((String) -> Void)?
    /// 一段新的语音刚开始（VAD 检测到声音）：比识别结果早 2 秒以上，用于“对方又开口了”的及时判断
    public var onSpeechStart: (() -> Void)?
    /// 同一段语音累计有声时间达到 sustainedSecs（构造时指定）时通知一次：用于确认“我真的在说话”（而不是一个噪声点）
    public var onSpeechSustained: (() -> Void)?

    private let q: DispatchQueue
    private let resampler = Resampler()
    private var running = false
    private var seg: [Float] = []
    private var pre: [Float] = []
    private var inSpeech = false
    private var silence = 0.0
    private var speechSecs = 0.0
    private var segID = 0
    private var segStart = Date()
    private var lastPartial = Date()
    private var partialBusy = false
    private var inflight = 0   // 正在识别的任务数，仅用于 waitIdle（评测等待结果落定）

    private let rate = 16000
    private let voiceThreshold: Float
    private let minSpeech: Double
    private let sustainedSecs: Double?
    private var sustainedFired = false
    private var lastVoiced: Date?

    /// 麦克风底噪/键盘声更多，阈值更高；系统音频较干净
    public init(speaker: String, voiceThreshold: Float = 0.008, minSpeech: Double = 0.3, sustainedSecs: Double? = nil) {
        self.speaker = speaker
        self.sustainedSecs = sustainedSecs
        self.voiceThreshold = voiceThreshold
        self.minSpeech = minSpeech
        q = DispatchQueue(label: "mc.whisper.\(speaker)")
    }

    public func start() { q.async { self.running = true } }

    public func stop() {
        q.async {
            if self.inSpeech { self.finalize() }
            self.running = false
        }
    }

    public func append(_ buf: AVAudioPCMBuffer) {
        let s = resampler.samples(buf)
        guard !s.isEmpty else { return }
        q.async { self.feed(s) }
    }

    private func feed(_ s: [Float]) {
        guard running else { return }
        let dur = Double(s.count) / Double(rate)
        var sum: Float = 0
        for v in s { sum += v * v }
        let voiced = (sum / Float(s.count)).squareRoot() > voiceThreshold

        if voiced {
            if !inSpeech {
                inSpeech = true; seg = pre; pre = []
                segID += 1; segStart = Date(); lastPartial = Date()
                sustainedFired = false
                onSpeechStart?()
            }
            seg += s; silence = 0; speechSecs += dur
            lastVoiced = Date()
            if let n = sustainedSecs, !sustainedFired, speechSecs >= n { sustainedFired = true; onSpeechSustained?() }
        } else if inSpeech {
            seg += s; silence += dur
            if silence >= 0.8 { finalize(); return }
        } else {
            pre += s
            if pre.count > rate * 3 / 10 { pre.removeFirst(pre.count - rate * 3 / 10) }
        }
        guard inSpeech else { return }
        if seg.count >= rate * 25 { finalize(); return }
        if !partialBusy, seg.count >= rate, Date().timeIntervalSince(lastPartial) > 2 { partial() }
    }

    /// 距离这一路最近一次检测到声音过去了多久（从没有声音返回无穷大）。用于区分“我在说话”和“对方的回声”。
    public func secondsSinceVoice() -> TimeInterval {
        q.sync { lastVoiced.map { Date().timeIntervalSince($0) } ?? .infinity }
    }

    /// 等到所有正在进行的识别任务都完成（评测/测试用，不影响正常运行）
    public func waitIdle() async {
        while q.sync(execute: { inflight > 0 }) { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func partial() {
        partialBusy = true
        inflight += 1
        let id = segID, start = segStart, snapshot = seg
        Task {
            let text = try? await WhisperEngine.shared.transcribe(snapshot)
            q.async {
                self.inflight -= 1
                self.partialBusy = false
                self.lastPartial = Date()
                if let text, !text.isEmpty, self.running {
                    self.onUpdate?(SegmentUpdate(id: id, start: start, text: text, isFinal: false))
                }
            }
        }
    }

    private func finalize() {
        let id = segID, start = segStart, samples = seg
        let end = Date().addingTimeInterval(-silence)
        let worthIt = speechSecs >= minSpeech
        seg = []; inSpeech = false; silence = 0; speechSecs = 0
        guard worthIt else {
            onUpdate?(SegmentUpdate(id: id, start: start, text: "", isFinal: true, end: end)); return
        }
        inflight += 1
        Task {
            do {
                let text = try await WhisperEngine.shared.transcribe(samples)
                q.async { self.inflight -= 1; self.onUpdate?(SegmentUpdate(id: id, start: start, text: text, isFinal: true, end: end)) }
            } catch {
                q.async {
                    self.inflight -= 1
                    self.onError?("识别失败：\(error.localizedDescription)")
                    self.onUpdate?(SegmentUpdate(id: id, start: start, text: "", isFinal: true, end: end))
                }
            }
        }
    }
}

public enum Permissions {
    public static func microphone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
