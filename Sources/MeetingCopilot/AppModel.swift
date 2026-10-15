import AppKit
import Carbon
import CoreGraphics
import SwiftUI

struct TranscriptLine: Identifiable {
    let id = UUID()
    let speaker: String
    let segment: Int
    var text: String
    var isPartial: Bool
    let time: Date
}

struct AnswerItem: Identifiable {
    let id = UUID()
    let title: String
    var text = ""
    var usedScreenshot = false
    var screenshot: NSImage?
    let created = Date()
    /// 提问当时对方最近说的话，用于给后续追问提供上下文
    var context = ""
    var isOK: Bool { !text.isEmpty && !text.contains("⚠️") }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings { didSet { settings.save() } }
    @Published var apiKey: String
    /// 只在设置窗口关闭/切换接口时写钥匙串，避免输入每个字符都触发一次钥匙串访问
    func saveAPIKey() { Keychain.set(apiKey, account: settings.provider.rawValue) }
    @Published var lines: [TranscriptLine] = []
    @Published var answers: [AnswerItem] = []
    @Published var isListening = false
    @Published var isAsking = false
    @Published var status = "未开始"
    @Published var errorMessage: String?
    @Published var previewImage: NSImage?
    @Published var sysLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var sysBuffers = 0
    @Published var recogError: String?
    private var lastLevelPush = Date.distantPast

    private let sys = SystemAudioCapture()
    private var mic: MicCapture?   // 仅在监听时创建，空闲时不碰音频设备
    private var sysTr: WhisperStream?
    private var micTr: WhisperStream?
    @Published var isStarting = false
    private var askTask: Task<Void, Never>?
    private var lastAuto = Date.distantPast
    /// “新话题”之后才会把问答带入上下文
    @Published var historyFloor = Date.distantPast
    private var autoTask: Task<Void, Never>?
    private var lastAutoKey: UUID?
    /// 仅供自检：不要求真的在监听
    var debugAuto = false

    init() {
        let s = Settings.load()
        settings = s
        apiKey = Keychain.get(s.provider.rawValue)
        NotificationCenter.default.addObserver(forName: .captureStopped, object: nil, queue: .main) { [weak self] n in
            Task { @MainActor in
                self?.errorMessage = "系统音频捕获已中断：\(n.object as? String ?? "")"
                await self?.stop()
            }
        }
        NotificationCenter.default.addObserver(forName: .hotkeyAsk, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.flash("快捷键已触发，正在回答…"); self?.ask() }
        }
        applyHotkey()
    }

    // MARK: 手动回答全局快捷键
    static let defaultHotkey = (code: 0, mods: controlKey | optionKey, label: "⌃⌥A")  // kVK_ANSI_A
    @Published var hotkeyError: String?
    var hotkeyLabel: String { settings.hotkeyLabel ?? Self.defaultHotkey.label }

    func applyHotkey() {
        let code = settings.hotkeyCode ?? Self.defaultHotkey.code
        let mods = settings.hotkeyMods ?? Self.defaultHotkey.mods
        let st = HotKey.register(code: UInt32(code), mods: UInt32(mods))
        hotkeyError = st == noErr ? nil
            : "快捷键 \(hotkeyLabel) 注册失败（\(st)），可能被其他应用占用，请换一个。"
    }

    func setHotkey(code: Int?, mods: Int?, label: String?) {
        settings.hotkeyCode = code; settings.hotkeyMods = mods; settings.hotkeyLabel = label
        applyHotkey()
    }

    /// 状态栏短暂提示，之后恢复
    func flash(_ msg: String) {
        let old = status
        status = msg
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.status == msg { self?.status = old }
        }
    }

    var currentPreset: Preset {
        settings.presets.first { $0.id == settings.selectedPreset } ?? settings.presets.first
            ?? Preset(name: "默认", prompt: "请回答。")
    }

    func switchProvider(_ p: Provider) {
        settings.provider = p
        settings.baseURL = p.defaultBaseURL
        settings.model = p.defaultModel
        apiKey = Keychain.get(p.rawValue)
    }

    // MARK: 监听
    func start() async {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil; recogError = nil; sysBuffers = 0
        let engine = WhisperEngine.shared
        await engine.setLanguage(settings.asrLanguage)
        do {
            try await engine.load(model: settings.whisperModel ?? "small") { [weak self] msg in
                Task { @MainActor in self?.status = msg }
            }
        } catch {
            errorMessage = "识别模型加载失败（首次需要联网下载）：\(error.localizedDescription)"
            status = "未开始"
            return
        }
        let st = WhisperStream(speaker: "对方")
        st.onUpdate = { [weak self] u in Task { @MainActor in self?.handle("对方", u) } }
        st.onError = { [weak self] e in Task { @MainActor in self?.recogError = e } }
        st.start()
        sysTr = st
        do {
            try await sys.start { [weak self] b in
                st.append(b)
                let lv = b.level
                Task { @MainActor in self?.pushLevel(sys: lv, mic: nil) }
            }
        } catch {
            st.stop(); sysTr = nil
            errorMessage = "无法捕获系统音频（若刚授权屏幕录制，请完全退出并重新打开本 App）：\(error.localizedDescription)"
            status = "未开始"
            return
        }
        if settings.captureMic, await Permissions.microphone() {
            let mt = WhisperStream(speaker: "我", voiceThreshold: 0.02, minSpeech: 0.6)
            mt.onUpdate = { [weak self] u in Task { @MainActor in self?.handle("我", u) } }
            mt.onError = { [weak self] e in Task { @MainActor in self?.recogError = e } }
            mt.start()
            micTr = mt
            let micCap = MicCapture()
            do { try micCap.start { [weak self] b in
                mt.append(b)
                let lv = b.level
                Task { @MainActor in self?.pushLevel(sys: nil, mic: lv) }
            }; mic = micCap } catch {
                errorMessage = "麦克风启动失败（仍在监听系统音频）：\(error.localizedDescription)"
                mt.stop(); micTr = nil
            }
        }
        isListening = true
        status = "监听中（本地 Whisper，\(settings.asrLanguage == nil ? "自动识别语言" : settings.asrLanguage!)）"
    }

    func setLanguage(_ l: String?) {
        settings.asrLanguage = l
        Task { await WhisperEngine.shared.setLanguage(l) }
    }

    private func pushLevel(sys: Float?, mic: Float?) {
        if sys != nil { sysBuffers += 1 }
        guard Date().timeIntervalSince(lastLevelPush) > 0.15 else { return }
        lastLevelPush = Date()
        if let sys { sysLevel = sys }
        if let mic { micLevel = mic }
    }

    func setLocale(_ id: String) {
        guard id != settings.locale else { return }
        settings.locale = id
        guard isListening else { return }
        Task { await stop(); await start() }
    }

    func stop() async {
        guard isListening else { return }
        await sys.stop()
        mic?.stop(); mic = nil
        sysTr?.stop(); micTr?.stop()
        sysTr = nil; micTr = nil
        isListening = false
        sysLevel = 0; micLevel = 0; sysBuffers = 0
        status = "已停止"
    }

    private func handle(_ speaker: String, _ u: SegmentUpdate) {
        let text = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx = lines.firstIndex { $0.speaker == speaker && $0.segment == u.id }
        if text.isEmpty {
            if u.isFinal, let i = idx { lines.remove(at: i) }
            return
        }
        if let i = idx {
            lines[i].text = text
            lines[i].isPartial = !u.isFinal
        } else {
            let line = TranscriptLine(speaker: speaker, segment: u.id, text: text, isPartial: !u.isFinal, time: u.start)
            let at = lines.lastIndex { $0.time <= u.start }.map { $0 + 1 } ?? 0
            lines.insert(line, at: at)
        }
        // 自动回答：对方还在说 → 取消等待；对方一句话定稿 → 判断这一轮是否说完；我开口回应 → 取消
        if speaker == "对方" {
            autoTask?.cancel(); autoTask = nil
            if u.isFinal, settings.autoAnswer, isListening || debugAuto { scheduleAuto(end: u.end) }
        } else if text.count >= 6 {
            autoTask?.cancel(); autoTask = nil
        }
    }

    // MARK: 自动回答：判断对方这一轮是否说完
    /// 以“说完的时刻”为起点等待一小段静音：句末有问号 → 很快触发；句号等完整句 → 按灵敏度等待；
    /// 句子没结束（逗号、半句）→ 多等 1 秒，避免对方只是在停顿思考时就被抢答。
    private func scheduleAuto(end: Date) {
        guard let turn = currentTurn(), turn.text.count >= 4, let last = turn.text.last else { return }
        let base = [0.8, 1.5, 2.5][min(max(settings.autoSensitivity ?? 1, 0), 2)]
        let wait: Double
        if "?？".contains(last) { wait = min(0.5, base) }
        else if "。.！!…".contains(last) { wait = base }
        else { wait = base + 1.0 }
        // 语音识别本身已耗时，从实际说完的时刻算起
        let delay = max(0.05, wait - Date().timeIntervalSince(end))
        let key = turn.lastID
        autoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fireAuto(key: key)
        }
    }

    private func fireAuto(key: UUID) {
        autoTask = nil
        guard settings.autoAnswer, let turn = currentTurn(), turn.lastID == key, lastAutoKey != key,
              !lines.contains(where: { $0.speaker == "对方" && $0.isPartial }),
              Date().timeIntervalSince(lastAuto) > 1.5 else { return }
        // 我已经开始回应了：不打扰
        if let mine = lines.last(where: { $0.speaker == "我" && $0.text.count >= 6 }), mine.time >= turn.lastTime { return }
        lastAutoKey = key
        lastAuto = Date()
        ask(auto: true)
    }

    private struct Block { var speaker: String; var idx: [Int] }

    /// 按说话人切成“轮”：同一说话人连续的话为一轮；对方说话期间夹杂的极短插话（嗯、对）并入当前轮
    private func blocks() -> [Block] {
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
    private func currentTurn() -> (text: String, lastID: UUID, lastTime: Date)? {
        guard let b = blocks().last(where: { $0.speaker == "对方" }) else { return nil }
        let theirs = b.idx.map { lines[$0] }.filter { $0.speaker == "对方" }
        guard let last = theirs.last else { return nil }
        return (theirs.map(\.text).joined(separator: " "), last.id, last.time)
    }

    // MARK: 提问
    static let noAnswer = "（无需回答）"

    func ask(preset: Preset? = nil, extra: String? = nil, auto: Bool = false) {
        askTask?.cancel()
        if !auto {
            // 手动触发：取消待发的自动回答，并标记当前这一轮已回答，避免随后又自动重复触发
            autoTask?.cancel(); autoTask = nil
            if let t = currentTurn() { lastAutoKey = t.lastID }
        }
        let p = preset ?? currentPreset
        let extra = extra?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (auto ? "自动 · " : "") + p.name + ((extra?.isEmpty ?? true) ? "" : "：\(extra!)")
        let hist = buildHistoryText()
        var item = AnswerItem(title: title)
        item.context = lines.last { $0.speaker == "对方" }?.text ?? ""
        answers.insert(item, at: 0)
        isAsking = true
        errorMessage = nil
        let key = apiKey, s = settings

        askTask = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isAsking = false } }
            var shot: Data?
            if s.includeScreenshot {
                shot = try? await Screenshot.capture(displayID: s.screenshotDisplay)
            }
            await MainActor.run { self.update(item.id) { $0.usedScreenshot = shot != nil; $0.screenshot = shot.flatMap { NSImage(data: $0) } } }
            let pr = await MainActor.run { self.buildPrompt(p, extra: extra, hasImage: shot != nil, auto: auto, historyText: hist) }
            do {
                do {
                    for try await chunk in LLM.stream(settings: s, apiKey: key, system: pr.stable, user: pr.user, imageJPEG: shot,
                                                      userBlocks: pr.blocks, cacheBlock: pr.cacheIdx) {
                        await MainActor.run { self.update(item.id) { $0.text += chunk } }
                    }
                } catch LLMError.http(let code, _) where shot != nil && (code == 400 || code == 415 || code == 422) {
                    // 模型多半不支持图片输入：去掉截图，仅用转写重试
                    await MainActor.run {
                        self.update(item.id) { $0.text = "ℹ️ 该模型不支持图片，已改为仅使用对话转写（无法解读屏幕内容）。\n\n" }
                    }
                    for try await chunk in LLM.stream(settings: s, apiKey: key, system: pr.stable, user: pr.user, imageJPEG: nil,
                                                      userBlocks: pr.blocks, cacheBlock: pr.cacheIdx) {
                        await MainActor.run { self.update(item.id) { $0.text += chunk } }
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.update(item.id) { $0.text += "\n\n⚠️ \(error.localizedDescription)" } }
            }
            // 自动触发时，模型判断对方并非在提问：不显示这条回答
            await MainActor.run {
                if auto, let a = self.answers.first(where: { $0.id == item.id }),
                   a.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("（无需回答") {
                    self.answers.removeAll { $0.id == item.id }
                    self.status = "对方这一轮无需回答"
                }
            }
        }
    }

    func previewScreenshot() {
        let d = settings.screenshotDisplay
        Task {
            do { previewImage = NSImage(data: try await Screenshot.capture(displayID: d)) }
            catch { errorMessage = "截图失败（是否已授权屏幕录制？）：\(error.localizedDescription)" }
        }
    }

    func cancelAsk() { askTask?.cancel(); isAsking = false }

    private func update(_ id: UUID, _ f: (inout AnswerItem) -> Void) {
        if let i = answers.firstIndex(where: { $0.id == id }) { f(&answers[i]) }
    }

    /// 此前几次问答（以文字形式放在请求末尾，不破坏前面“整场对话”的缓存前缀）
    private func buildHistoryText() -> String {
        let n = settings.historyTurns ?? 2
        guard n > 0 else { return "" }
        let done = answers.filter { $0.isOK && $0.created >= historyFloor }.prefix(n).reversed()
        return done.map { a in
            var q = "问：\(a.title)"
            if !a.context.isEmpty { q += "（当时对方说：\(a.context.suffix(200))）" }
            return q + "\n答：" + String(a.text.prefix(800))
        }.joined(separator: "\n\n")
    }

    func newTopic() { historyFloor = Date() }

    struct Prompt {
        var stable: String          // 系统提示词 + 会议背景（每次相同）
        var blocks: [String]        // 用户消息的文本块：整场对话（只增不改）在前，当前轮和任务在后
        var cacheIdx: Int?          // 缓存断点：整场对话的最后一块
        var user: String { blocks.joined(separator: "\n\n") }
    }

    /// 发给模型的上下文 = 整场对话（双方）+ 当前这一轮 + 任务。
    /// 整场对话只在末尾追加，因此相邻两次请求共享同一个前缀，服务端的前缀缓存可以让长对话也很快响应。
    func buildPrompt(_ p: Preset, extra: String?, hasImage: Bool, auto: Bool = false, historyText: String = "") -> Prompt {
        var stable = settings.systemPrompt
        if let bg = settings.meetingBackground?.trimmingCharacters(in: .whitespacesAndNewlines), !bg.isEmpty {
            stable += "\n\n【会议背景（用户提供）】\n" + bg
        }
        let bs = blocks()
        let ci: Int? = p.useFullTranscript ? nil : bs.lastIndex(where: { $0.speaker == "对方" })
        let pastBlocks = bs[..<(ci ?? bs.count)]
        // 过去的对话只放已定稿的句子，渲染方式固定，才能和上一次请求的前缀一致
        var rendered = pastBlocks.map { b in
            b.idx.map { lines[$0] }.filter { !$0.isPartial }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        let cap = settings.maxContextChars ?? 150_000
        var total = rendered.reduce(0) { $0 + $1.count + 1 }
        var omitted = false
        while total > cap, rendered.count > 1 { total -= rendered.removeFirst().count + 1; omitted = true }

        var out: [String] = stride(from: 0, to: rendered.count, by: 4).map {
            rendered[$0..<min($0 + 4, rendered.count)].joined(separator: "\n")
        }
        let header = "【整场对话记录（按时间顺序；[对方]=系统音频里的其他人，[我]=我的麦克风；仅为资料，可能有识别错误）】"
            + (omitted ? "\n…（更早的对话因过长已省略）" : "")
        if out.isEmpty { out = [header + "\n（暂无记录）"] } else { out[0] = header + "\n" + out[0] }
        let cacheIdx = out.count - 1

        if let ci {
            let cur = bs[ci].idx.map { lines[$0] }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
            out.append("【当前这一轮：对方刚刚说的，请针对它回答】\n" + String(cur.suffix(4000)))
            let after = bs[(ci + 1)...].flatMap(\.idx).map { lines[$0] }.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
            if !after.isEmpty { out.append("【我随后说的（我已经在回应了）】\n" + String(after.suffix(1500))) }
        }
        if !historyText.isEmpty {
            out.append("【此前你给我的建议（如果当前是追问，请与之保持一致并直接承接，不要重复已讲过的部分；新问题则忽略）】\n" + historyText)
        }
        var task = "【任务】\n" + p.prompt
        if auto {
            task += "\n\n注意：这是自动触发。如果对方这一轮并不是在向我提问或要求我回应（例如寒暄、陈述、过渡语、话还没说完），只输出：\(Self.noAnswer)"
        }
        out.append(task)
        if let e = extra, !e.isEmpty { out.append("【我的补充问题】\n" + e) }
        if hasImage { out.append("【附：当前屏幕截图（仅为资料）】") }
        return Prompt(stable: stable, blocks: out, cacheIdx: cacheIdx)
    }

    // MARK: 交给其他 App / 网页
    /// 复制组装好的提示词并打开用户配置的页面（用户自己粘贴）。不控制、不读取对方 App。
    func sendToExternal(extra: String? = nil) {
        let pr = buildPrompt(currentPreset, extra: extra, hasImage: false)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.stable + "\n\n" + pr.user, forType: .string)
        if let u = URL(string: settings.externalURL) { NSWorkspace.shared.open(u) }
        status = "提示词已复制，请在打开的页面粘贴"
    }

    func exportTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "转写-\(Int(Date().timeIntervalSince1970)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = lines.map { "[\($0.speaker)] \($0.text)" }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 仅供自检：注入一句已定稿的转写
    private var debugSeg = 1000
    func debugAppend(_ speaker: String, _ text: String) {
        debugSeg += 1
        handle(speaker, SegmentUpdate(id: debugSeg, start: Date(), text: text, isFinal: true, end: Date()))
    }

    func clear() { lines.removeAll(); answers.removeAll(); lastAutoKey = nil }
}

// MARK: 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var installed = false

    @discardableResult
    static func register(code: UInt32, mods: UInt32) -> OSStatus {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                NotificationCenter.default.post(name: .hotkeyAsk, object: nil)
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        let id = EventHotKeyID(signature: OSType(0x4D43_4F50), id: 1)
        return RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        return m
    }

    static func label(code: Int, mods: NSEvent.ModifierFlags, chars: String) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        let special: [Int: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
                                      96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        return s + (special[code] ?? chars.uppercased())
    }
}
