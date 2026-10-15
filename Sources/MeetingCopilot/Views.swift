import AVFoundation
import SwiftUI

@main
struct MeetingCopilotApp: App {
    @StateObject private var model = AppModel()

    init() {
        HotKey.register()
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-whisper") { WhisperSelfTest.run(args: Array(CommandLine.arguments.dropFirst(i + 1))) }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-context") { ContextSelfTest.run(port: CommandLine.arguments[i + 1]) }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-llm") {
            SelfTest.run(args: Array(CommandLine.arguments.dropFirst(i + 1)))
        }
    }

    var body: some Scene {
        WindowGroup("MeetingCopilot") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 560)
        }
    }
}

/// 无 UI 的 LLM 通路自检：--selftest-llm <openai|anthropic> <baseURL> <model> [key]
enum SelfTest {
    static func run(args: [String]) {
        guard args.count >= 3 else { print("usage: --selftest-llm <openai|anthropic> <baseURL> <model> [key]"); exit(2) }
        var s = Settings()
        s.provider = Provider(rawValue: args[0]) ?? .openai
        s.baseURL = args[1]; s.model = args[2]
        Task {
            do {
                for try await c in LLM.stream(settings: s, apiKey: args.count > 3 ? args[3] : "",
                                              system: "sys", user: "hi", imageJPEG: Data([1, 2, 3]),
                                              history: [ChatTurn(user: "q1", assistant: "a1")]) {
                    print(c, terminator: "")
                }
                print("\n[selftest ok]"); exit(0)
            } catch { print("[selftest error] \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var floating: Bool
    var hidden: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { apply(v.window) } }
    private func apply(_ w: NSWindow?) {
        w?.level = floating ? .floating : .normal
        w?.sharingType = hidden ? .none : .readOnly
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var question = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                transcriptPane.frame(minWidth: 300)
                answerPane.frame(minWidth: 380)
            }
            Divider()
            inputBar
        }
        .background(WindowConfigurator(floating: m.settings.alwaysOnTop ?? false, hidden: m.settings.hideFromCapture ?? false))
        .sheet(isPresented: Binding(get: { m.previewImage != nil }, set: { if !$0 { m.previewImage = nil } })) {
            if let img = m.previewImage { ImagePreview(image: img, title: "当前会被截取的屏幕") }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(m) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { m.isListening ? await m.stop() : await m.start() }
            } label: {
                Label(m.isListening ? "停止监听" : "开始监听", systemImage: m.isListening ? "stop.circle.fill" : "record.circle")
            }
            .tint(m.isListening ? .red : .accentColor)
            .disabled(m.isStarting)
            Circle().fill(m.isListening ? Color.green : Color.gray).frame(width: 8, height: 8)
            Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 160, alignment: .leading)
            if m.isListening {
                LevelBar(title: "对方", level: m.sysLevel, count: m.sysBuffers)
                if m.settings.captureMic { LevelBar(title: "我", level: m.micLevel, count: nil) }
            }
            Spacer()
            Picker("语言", selection: Binding(get: { m.settings.asrLanguage ?? "auto" },
                                             set: { m.setLanguage($0 == "auto" ? nil : $0) })) {
                Text("自动").tag("auto"); Text("中文").tag("zh"); Text("English").tag("en")
            }.frame(width: 110).help("自动：识别中文/英文/中英混杂。固定语言可减少误判")
            Picker("预设", selection: Binding(get: { m.settings.selectedPreset ?? m.currentPreset.id },
                                             set: { m.settings.selectedPreset = $0 })) {
                ForEach(m.settings.presets) { Text($0.name).tag($0.id) }
            }.frame(width: 170)
            Button { m.ask() } label: { Label("立即回答", systemImage: "sparkles") }
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩，或全局 ⌃⌥Space")
            Toggle("自动回答", isOn: $m.settings.autoAnswer).toggleStyle(.switch).fixedSize().help("检测到对方提问时自动回答")
            Button { m.previewScreenshot() } label: { Image(systemName: "camera.viewfinder") }
                .help("预览将被截取的屏幕")
            Button { m.sendToExternal() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("复制提示词并打开外部 AI 页面")
            Toggle(isOn: Binding(get: { m.settings.alwaysOnTop ?? false }, set: { m.settings.alwaysOnTop = $0 })) { Image(systemName: "pin") }.toggleStyle(.button).help("窗口置顶")
            Button { m.exportTranscript() } label: { Image(systemName: "square.and.arrow.up") }.help("导出转写")
            Button { m.clear() } label: { Image(systemName: "trash") }.help("清空")
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .padding(10)
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(m.lines) { l in
                        (Text(l.speaker + "  ").bold().foregroundColor(l.speaker == "我" ? .blue : .orange)
                         + Text(l.text).foregroundColor(l.isPartial ? .secondary : .primary))
                            .textSelection(.enabled)
                            .id(l.id)
                    }
                    if m.lines.isEmpty {
                        Text("点击“开始监听”后，会议语音会实时出现在这里。").foregroundStyle(.secondary)
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: m.lines.last?.text) {
                if let id = m.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var answerPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if m.isListening, m.sysBuffers == 0 {
                    Text("尚未收到系统音频。请确认：已授权“屏幕与系统音频录制”并重启过 App；会议里确实有人在说话。")
                        .foregroundStyle(.orange)
                }
                if let e = m.recogError {
                    Text("⚠️ " + e).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let e = m.errorMessage {
                    Text(e).foregroundStyle(.red).padding(8)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                if !m.meetingSummary.isEmpty {
                    DisclosureGroup("会议摘要（自动维护，较早的对话已压缩到这里）") {
                        Text(m.meetingSummary).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption)
                    Divider()
                }
                ForEach(m.answers) { a in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(a.title).font(.caption.bold()).foregroundStyle(.secondary)
                            if a.usedScreenshot { Image(systemName: "photo").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let img = a.screenshot {
                            Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 260)
                                .border(Color.gray.opacity(0.4))
                                .onTapGesture { m.previewImage = img }
                                .help("本次解读所用的截图，点击放大")
                        }
                        Text(markdown(a.text.isEmpty ? "…" : a.text)).textSelection(.enabled)
                    }
                    Divider()
                }
                if m.answers.isEmpty && m.errorMessage == nil {
                    Text("AI 回答显示在这里。").foregroundStyle(.secondary)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("补充提问（可选，回车发送；留空则按预设直接回答）", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            Button("新话题") { m.newTopic() }
                .help("之后的回答不再参考此前的问答（转写不受影响）")
            if m.isAsking {
                Button("停止") { m.cancelAsk() }
            } else {
                Button("发送") { send() }
            }
        }
        .padding(10)
    }

    private func send() {
        m.ask(extra: question)
        question = ""
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var sel: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TabView {
                api.tabItem { Text("模型 API") }
                prompts.tabItem { Text("提示词") }
                general.tabItem { Text("通用") }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(10)
        }
        .frame(width: 680, height: 560)
        .onDisappear { m.saveAPIKey() }
    }

    private var api: some View {
        Form {
            Picker("接口类型", selection: Binding(get: { m.settings.provider }, set: { m.switchProvider($0) })) {
                ForEach(Provider.allCases) { Text($0.label).tag($0) }
            }
            TextField("Base URL", text: $m.settings.baseURL)
            TextField("模型", text: $m.settings.model)
            SecureField("API Key（存入钥匙串；本机 Ollama 可留空）", text: $m.apiKey)
            Text("非本机地址必须 https。Ollama 示例：类型选 OpenAI 兼容，Base URL 填 http://localhost:11434/v1。使用云端 API 时，转写文本与截图会发送给该服务商。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("提问时附带当前屏幕截图（需模型支持图片）", isOn: $m.settings.includeScreenshot)
            Picker("截图哪个屏幕", selection: $m.settings.screenshotDisplay) {
                Text("鼠标所在的屏幕").tag(UInt32?.none)
                ForEach(NSScreen.screens, id: \.self) { sc in
                    if let id = Screenshot.screenID(sc) { Text(sc.localizedName).tag(UInt32?.some(id)) }
                }
            }
            TextField("外部 AI 页面 URL", text: $m.settings.externalURL)
        }.padding()
    }

    private var prompts: some View {
        HStack(alignment: .top) {
            VStack {
                List(selection: $sel) {
                    ForEach(m.settings.presets) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("+") {
                        let p = Preset(name: "新预设", prompt: "请回答。")
                        m.settings.presets.append(p); sel = p.id
                    }
                    Button("−") {
                        if let s = sel, m.settings.presets.count > 1 {
                            m.settings.presets.removeAll { $0.id == s }; sel = nil
                        }
                    }
                }
            }.frame(width: 160)
            VStack(alignment: .leading) {
                if let i = m.settings.presets.firstIndex(where: { $0.id == sel }) {
                    TextField("名称", text: $m.settings.presets[i].name)
                    Text("预设提示词（追加在系统提示词之后）").font(.caption)
                    TextEditor(text: $m.settings.presets[i].prompt)
                        .font(.body).border(Color.gray.opacity(0.3))
                    Toggle("使用完整转写（会后总结）", isOn: $m.settings.presets[i].useFullTranscript)
                } else {
                    Text("在左侧选择预设进行编辑").foregroundStyle(.secondary)
                }
                Divider()
                Text("会议背景（岗位/简历要点/议题等，每次提问都会带上）").font(.caption)
                TextEditor(text: Binding(get: { m.settings.meetingBackground ?? "" }, set: { m.settings.meetingBackground = $0 }))
                    .font(.body).border(Color.gray.opacity(0.3)).frame(height: 80)
                Text("系统提示词（全局）").font(.caption)
                TextEditor(text: $m.settings.systemPrompt).font(.body).border(Color.gray.opacity(0.3))
                    .frame(height: 100)
                Button("恢复默认系统提示词") { m.settings.systemPrompt = Settings.defaultSystemPrompt }
            }
        }.padding()
    }

    private var general: some View {
        Form {
            Picker("语音识别模型（本地 Whisper）", selection: Binding(get: { m.settings.whisperModel ?? "small" },
                                                             set: { m.settings.whisperModel = $0 })) {
                Text("tiny（约 75MB，最快，准确度低）").tag("tiny")
                Text("base（约 140MB）").tag("base")
                Text("small（约 460MB，默认）").tag("small")
                Text("large-v3 turbo（约 630MB，最准，需要较好的 Mac）").tag("large-v3-v20240930_turbo_632MB")
            }
            Text("首次使用某个模型需联网下载并优化，之后离线可用；切换模型后重新点“开始监听”。").font(.caption).foregroundStyle(.secondary)
            Toggle("同时转写我的麦克风（标记为“我”）", isOn: $m.settings.captureMic)
            Toggle("智能上下文：当前这一轮 + 近期对话 + 自动会议摘要", isOn: Binding(get: { m.settings.smartContext ?? true }, set: { m.settings.smartContext = $0 }))
            Text("开启后：以对方最近一段连续发言为“当前这一轮”，更早的对话由后台压缩成摘要，回答既快又不丢上下文（摘要会额外调用一次模型）。关闭则按固定字数截取最近转写。").font(.caption).foregroundStyle(.secondary)
            Stepper("带入最近 \(m.settings.historyTurns ?? 2) 次问答作为上下文（0 = 不带）",
                    value: Binding(get: { m.settings.historyTurns ?? 2 }, set: { m.settings.historyTurns = $0 }), in: 0...6)
            Stepper("近期对话上限 \(m.settings.recentChars) 字（超出的部分会被摘要）", value: $m.settings.recentChars, in: 1000...30000, step: 1000)
            Toggle("窗口置顶（默认关闭）", isOn: Binding(get: { m.settings.alwaysOnTop ?? false }, set: { m.settings.alwaysOnTop = $0 }))
            Toggle("对截屏/录屏/屏幕共享隐藏本窗口（默认关闭）", isOn: Binding(get: { m.settings.hideFromCapture ?? false }, set: { m.settings.hideFromCapture = $0 }))
            Text("本 App 的截图始终排除自身窗口。新版 macOS 上“对屏幕共享隐藏”不一定对所有会议软件生效，共享屏幕前请自行确认。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

struct ImagePreview: View {
    let image: NSImage
    let title: String
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack {
            Text(title).font(.headline)
            Image(nsImage: image).resizable().scaledToFit()
            Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding().frame(width: 800, height: 520)
    }
}

struct LevelBar: View {
    let title: String
    let level: Float
    let count: Int?
    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).fixedSize()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                Capsule().fill(Color.green).frame(width: 50 * CGFloat(level))
            }.frame(width: 50, height: 6)
            if let count { Text("\(count)").font(.caption2).foregroundStyle(.secondary).fixedSize() }
        }.help("实时音量；“对方”后的数字是已收到的音频包数")
    }
}


/// 无 UI 自检：--selftest-whisper <model> <音频文件...>，把文件当作实时音频送入流式转写
enum WhisperSelfTest {
    static func run(args: [String]) {
        Task {
            func say(_ s: String) { print(s); fflush(stdout) }
            guard args.count >= 2 else { say("usage: --selftest-whisper <model> <file>..."); exit(2) }
            do {
                try await WhisperEngine.shared.load(model: args[0]) { say("[status] \($0)") }
            } catch { say("LOAD ERROR: \(error)"); exit(1) }
            let rs = Resampler()
            let stream = WhisperStream(speaker: "test")
            stream.onUpdate = { u in say("\(u.isFinal ? "FINAL  " : "partial") #\(u.id): \(u.text)") }
            stream.onError = { say("ERROR: \($0)") }
            stream.start()
            for path in args.dropFirst() {
                say("--- \(path)")
                guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                      let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { say("cannot read"); continue }
                try? f.read(into: buf)
                let samples = rs.samples(buf)
                say("samples=\(samples.count) (\(samples.count / 16000)s)")
                // 切成 100ms 包，加 1.5 秒静音收尾
                let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
                var all = samples + [Float](repeating: 0, count: 24000)
                while !all.isEmpty {
                    let n = min(1600, all.count)
                    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
                    b.frameLength = AVAudioFrameCount(n)
                    for i in 0..<n { b.floatChannelData![0][i] = all[i] }
                    all.removeFirst(n)
                    stream.append(b)
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
            stream.stop()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            exit(0)
        }
        RunLoop.main.run()
    }
}

/// 自检：模拟一场较长的面试，检查“当前轮 + 摘要 + 近期对话”的组装（配合本地 mock 服务）
enum ContextSelfTest {
    static func run(port: String) {
        Task { @MainActor in
            let m = AppModel()
            m.settings.baseURL = "http://127.0.0.1:\(port)/v1"
            m.settings.model = "mock"
            m.settings.includeScreenshot = false
            m.settings.meetingBackground = "岗位：机器学习工程师；我的简历要点：做过推荐系统召回。"
            for i in 1...12 {
                m.debugAppend("对方", "第\(i)个问题：" + String(repeating: "请介绍一下你在项目里用到的技术方案与取舍。", count: 7))
                m.debugAppend("我", "第\(i)个回答：" + String(repeating: "我们采用了双塔召回加重排的方案并做了离线评估。", count: 5))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            m.debugAppend("对方", "好的。那你在这个项目里具体负责哪一部分？")
            m.debugAppend("对方", "遇到的最大困难是什么，怎么解决的？")
            m.ask()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("SUMMARY-LEN \(m.meetingSummary.count)"); fflush(stdout)
            exit(0)
        }
        RunLoop.main.run()
    }
}
