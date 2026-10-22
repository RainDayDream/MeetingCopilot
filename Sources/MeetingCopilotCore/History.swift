import Foundation

/// 历史记录里的一条转写（只存定稿，不存 partial）。
public struct HistoryLine: Codable, Identifiable, Sendable {
    public var id: UUID
    public var speaker: String
    public var text: String
    public var time: Date

    public init(id: UUID = UUID(), speaker: String, text: String, time: Date) {
        self.id = id; self.speaker = speaker; self.text = text; self.time = time
    }
}

/// 历史记录里的一条 AI 回答（不保存截图）。
public struct HistoryAnswer: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String
    public var context: String
    public var created: Date

    public init(id: UUID = UUID(), title: String, text: String, context: String, created: Date) {
        self.id = id; self.title = title; self.text = text; self.context = context; self.created = created
    }
}

public struct HistorySession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lines: [HistoryLine]
    public var answers: [HistoryAnswer]

    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date,
                lines: [HistoryLine], answers: [HistoryAnswer]) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.lines = lines; self.answers = answers
    }

    /// 标题优先取对方的第一句话，没有就按时间生成。
    public static func makeTitle(lines: [HistoryLine], date: Date) -> String {
        if let first = lines.first(where: { $0.speaker == "对方" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text {
            let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.count > 28 ? String(t.prefix(28)) + "…" : t
        }
        return "对话 " + date.formatted(date: .numeric, time: .shortened)
    }
}

/// 本机历史存储：Application Support/MeetingCopilot/history/<uuid>.json。
/// 只在主线程调用（AppModel 在 @MainActor 上使用）；测试可注入临时目录。
public final class HistoryStore {
    public let directory: URL
    public let maxSessions: Int

    public init(directory: URL? = nil, maxSessions: Int = 50) {
        self.maxSessions = maxSessions
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("MeetingCopilot/history", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func load() -> [HistorySession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [HistorySession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let s = try? decoder.decode(HistorySession.self, from: data) else { continue }
            out.append(s)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ session: HistorySession) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(session) else { return }
        let url = directory.appendingPathComponent(session.id.uuidString + ".json")
        try? data.write(to: url, options: .atomic)
        trim()
    }

    public func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }

    public func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func trim() {
        let all = load()
        guard all.count > maxSessions else { return }
        for s in all.dropFirst(maxSessions) { delete(s.id) }
    }
}
