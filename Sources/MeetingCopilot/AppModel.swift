import AppKit
import Carbon
import CoreGraphics
import MeetingCopilotCore
import SwiftUI

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
    /// “新话题”之后才会把问答带入上下文
    @Published var historyFloor = Date.distantPast
    private var autoTask: Task<Void, Never>?
    private let detector = TurnDetector()
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
        if !RuntimeFlags.isolated { applyHotkey() }
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
        st.onSpeechStart = { [weak self] in Task { @MainActor in self?.speechStarted("对方") } }
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
            let mt = WhisperStream(speaker: "我", voiceThreshold: 0.02, minSpeech: 0.6, sustainedSecs: 0.8)
            mt.onUpdate = { [weak self] u in Task { @MainActor in self?.handle("我", u) } }
            mt.onError = { [weak self] e in Task { @MainActor in self?.recogError = e } }
            mt.onSpeechSustained = { [weak self] in Task { @MainActor in self?.meSpeaking() } }
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
        guard TranscriptOps.apply(&lines, speaker: speaker, segment: u.id, start: u.start, text: u.text, isFinal: u.isFinal) else {
            // 一段声音结束但没有文字：如果之前因它取消了待触发，重新安排（否则会漏答）
            if u.isFinal {
                perform(detector.onEmptyFinal(lines: lines, speaker: speaker, autoEnabled: autoEnabled, sensitivity: settings.autoSensitivity))
            }
            return
        }
        // 自动回答：由 TurnDetector 判断是取消等待、重新安排，还是不处理
        perform(detector.onUpdate(lines: lines, speaker: speaker, text: u.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  isFinal: u.isFinal, end: u.end, autoEnabled: autoEnabled, sensitivity: settings.autoSensitivity))
    }

    private var autoEnabled: Bool { settings.autoAnswer && (isListening || debugAuto) }

    /// VAD 检测到某一路开始出现语音：对方重新开口就立刻取消待触发（比识别结果早 2 秒以上）
    private func speechStarted(_ speaker: String) {
        perform(detector.onSpeechStart(speaker: speaker))
    }

    /// 麦克风持续有声：确认我在说话（对方那一路已安静）就取消待触发，不打扰
    private func meSpeaking() {
        perform(detector.onMeSpeaking(systemSilentFor: sysTr?.secondsSinceVoice() ?? .infinity))
    }

    private func perform(_ action: TurnDetector.Action) {
        switch action {
        case .none: break
        case .cancel: autoTask?.cancel(); autoTask = nil
        case .schedule(let delay, let key):
            autoTask?.cancel()
            autoTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.fireAuto(key: key)
            }
        }
    }

    private func fireAuto(key: UUID) {
        autoTask = nil
        guard settings.autoAnswer, detector.shouldFire(key: key, lines: lines) else { return }
        ask(auto: true)
    }

    // MARK: 提问
    static let noAnswer = noAnswerSentinel

    func ask(preset: Preset? = nil, extra: String? = nil, auto: Bool = false) {
        askTask?.cancel()
        if !auto {
            // 手动触发：取消待发的自动回答，并标记当前这一轮已回答，避免随后又自动重复触发
            autoTask?.cancel(); autoTask = nil
            detector.markManual(lines: lines)
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

    private func buildHistoryText() -> String {
        ContextBuilder.historyText(entries: answers.map { HistoryEntry(title: $0.title, context: $0.context, text: $0.text, created: $0.created) },
                                   count: settings.historyTurns ?? 2, since: historyFloor)
    }

    func newTopic() { historyFloor = Date() }

    func buildPrompt(_ p: Preset, extra: String?, hasImage: Bool, auto: Bool = false, historyText: String = "") -> Prompt {
        ContextBuilder.build(lines: lines,
                             preset: PresetSpec(prompt: p.prompt, useFullTranscript: p.useFullTranscript),
                             options: ContextOptions(systemPrompt: settings.systemPrompt, meetingBackground: settings.meetingBackground,
                                                     maxContextChars: settings.maxContextChars ?? 150_000, extra: extra,
                                                     hasImage: hasImage, auto: auto, historyText: historyText))
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

    func clear() { lines.removeAll(); answers.removeAll(); detector.reset() }
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
