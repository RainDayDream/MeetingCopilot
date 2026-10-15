import Foundation

/// 评测数据模型与加载。数据集（eval/）已冻结，见 eval/README.md。
struct EvalEvent: Decodable {
    let speaker: String
    let text: String
    let start: Double
    let end: Double
    let kind: String            // speech | echo
}

struct EvalExpect: Decodable {
    let id: String
    let shouldAnswer: Bool
    let turnStart: Double
    let questionEnd: Double
    let questionText: String
    let replyStart: Double?
    let windowEnd: Double
    let note: String
}

struct EvalDialog: Decodable {
    let id: String
    let category: String
    let lang: String
    let description: String
    let events: [EvalEvent]
    let expected: [EvalExpect]

    /// 某个标注轮次里对方实际说出的各段文本
    func questionSegments(_ x: EvalExpect) -> [String] {
        events.filter { $0.speaker == "对方" && $0.kind == "speech" && $0.start >= x.turnStart - 1e-6 && $0.end <= x.questionEnd + 1e-6 }
            .map(\.text)
    }
}

struct EvalAudioClip: Decodable {
    let file: String
    let sampleRate: Int
    let duration: Double
    let micNoise: Bool
    let echo: Bool
    let reference: [String: String]
}

enum EvalPaths {
    /// 仓库根目录（由本文件位置推出：Tests/MeetingCopilotCoreTests/Support/）
    static let root: URL = {
        if let r = ProcessInfo.processInfo.environment["EVAL_ROOT"] { return URL(fileURLWithPath: r) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }()
    static var eval: URL { root.appendingPathComponent("eval") }
    static var dialogs: URL { eval.appendingPathComponent("dialogs") }
    static var audio: URL { eval.appendingPathComponent("audio") }
    static var results: URL { eval.appendingPathComponent("results") }
    static var partial: URL { results.appendingPathComponent(".partial") }
    static var cache: URL { eval.appendingPathComponent(".cache") }
}

enum EvalData {
    static func loadDialogs() throws -> [EvalDialog] {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let files = try FileManager.default.contentsOfDirectory(at: EvalPaths.dialogs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try dec.decode(EvalDialog.self, from: Data(contentsOf: $0)) }
    }

    static func loadManifest() throws -> [String: EvalAudioClip] {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode([String: EvalAudioClip].self, from: Data(contentsOf: EvalPaths.audio.appendingPathComponent("manifest.json")))
    }

    static func writePartial(_ name: String, _ obj: Any) throws {
        try FileManager.default.createDirectory(at: EvalPaths.partial, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: EvalPaths.partial.appendingPathComponent(name + ".json"))
    }
}
