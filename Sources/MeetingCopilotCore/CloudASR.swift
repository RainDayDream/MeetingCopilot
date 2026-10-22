import Foundation

/// 一段音频的转写器。WhisperStream 只负责 VAD/切句，具体用本地还是云端由这里决定。
public protocol SegmentTranscriber: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public struct LocalWhisperTranscriber: SegmentTranscriber {
    public init() {}
    public func transcribe(_ samples: [Float]) async throws -> String {
        try await WhisperEngine.shared.transcribe(samples)
    }
}

public enum CloudASRError: LocalizedError {
    case missingKey
    case connection(String)
    case taskFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "未配置阿里云百炼 API Key"
        case .connection(let s): return "云端识别连接失败：\(s)"
        case .taskFailed(let s): return "云端识别失败：\(s)"
        case .timeout: return "云端识别超时"
        }
    }
}

/// 阿里云百炼 Paraformer 实时识别。按 VAD 切出的一段音频建立一个短 WebSocket 任务：
/// run-task → 发送 16k/单声道 PCM → finish-task → 收集 sentence_end=true 的文本。
/// 文档：https://help.aliyun.com/zh/model-studio/websocket-for-paraformer-real-time-service
public struct AliyunParaformerTranscriber: SegmentTranscriber {
    public static let defaultEndpoint = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!
    public static let defaultModel = "paraformer-realtime-v2"

    private let apiKey: String
    private let model: String
    private let languageHints: [String]
    private let endpoint: URL

    public init(apiKey: String, model: String = defaultModel, language: String? = nil,
                endpoint: URL = defaultEndpoint) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.languageHints = [language].compactMap { $0 }.filter { ["zh", "en", "yue", "ja", "ko", "de", "fr", "ru"].contains($0) }
        self.endpoint = endpoint
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudASRError.missingKey }
        guard !samples.isEmpty else { return "" }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()

        let flag = TimeoutFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await flag.fire()
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        do {
            let taskID = UUID().uuidString
            try await sendJSON(Self.runTask(taskID: taskID, model: model, languageHints: languageHints), on: task)
            try await waitForStarted(task)

            var offset = 0
            while offset < samples.count {
                let end = min(offset + 3200, samples.count)   // 200ms
                try await task.send(.data(Self.pcm16(Array(samples[offset..<end]))))
                offset = end
            }
            try await sendJSON(Self.finishTask(taskID: taskID), on: task)

            var finals: [String] = []
            var lastPartial = ""
            while true {
                let text = try await receiveText(task)
                guard let event = Self.parseServerEvent(text) else { continue }
                switch event.name {
                case "task-failed":
                    throw CloudASRError.taskFailed(event.error ?? "未知错误")
                case "result-generated":
                    if let t = event.text, !t.isEmpty {
                        if event.sentenceEnd { finals.append(t) } else { lastPartial = t }
                    }
                case "task-finished":
                    let joined = finals.joined()
                    return WhisperEngine.clean(joined.isEmpty ? lastPartial : joined)
                default:
                    continue
                }
            }
        } catch let e as CloudASRError {
            throw e
        } catch {
            if await flag.isFired { throw CloudASRError.timeout }
            throw CloudASRError.connection(error.localizedDescription)
        }
    }

    // MARK: - Protocol messages (internal for tests)

    static func runTask(taskID: String, model: String, languageHints: [String]) -> [String: Any] {
        var params: [String: Any] = [
            "format": "pcm",
            "sample_rate": 16000,
            "disfluency_removal_enabled": false,
            "semantic_punctuation_enabled": false,
            "max_sentence_silence": 800,
            "punctuation_prediction_enabled": true,
            "inverse_text_normalization_enabled": true
        ]
        if !languageHints.isEmpty { params["language_hints"] = languageHints }
        return [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": params,
                "input": [:]
            ]
        ]
    }

    static func finishTask(taskID: String) -> [String: Any] {
        ["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
         "payload": ["input": [:]]]
    }

    struct ServerEvent {
        let name: String
        let text: String?
        let sentenceEnd: Bool
        let error: String?
    }

    static func parseServerEvent(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = obj["header"] as? [String: Any],
              let name = header["event"] as? String else { return nil }
        let output = (obj["payload"] as? [String: Any])?["output"] as? [String: Any]
        let sentence = output?["sentence"] as? [String: Any]
        let err = [header["error_code"], header["error_message"]].compactMap { $0 as? String }.joined(separator: "：")
        return ServerEvent(name: name,
                           text: sentence?["text"] as? String,
                           sentenceEnd: (sentence?["sentence_end"] as? Bool) ?? false,
                           error: err.isEmpty ? nil : err)
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            var v = Int16(clamped * 32767).littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - WebSocket helpers

    private func sendJSON(_ obj: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let s = String(data: data, encoding: .utf8) else { throw CloudASRError.connection("无法编码请求") }
        try await task.send(.string(s))
    }

    private func waitForStarted(_ task: URLSessionWebSocketTask) async throws {
        while true {
            let text = try await receiveText(task)
            guard let event = Self.parseServerEvent(text) else { continue }
            if event.name == "task-started" { return }
            if event.name == "task-failed" { throw CloudASRError.taskFailed(event.error ?? "任务启动失败") }
        }
    }

    private func receiveText(_ task: URLSessionWebSocketTask) async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }
}

private actor TimeoutFlag {
    private var fired = false
    func fire() { fired = true }
    var isFired: Bool { fired }
}
