import Foundation
import Testing
@testable import MeetingCopilotCore

struct HistoryStoreTests {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("mc-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func session(_ title: String, date: Date) -> HistorySession {
        HistorySession(title: title, createdAt: date, updatedAt: date,
                       lines: [HistoryLine(speaker: "对方", text: "你好", time: date)],
                       answers: [HistoryAnswer(title: "实时回答", text: "你好。", context: "你好", created: date)])
    }

    @Test func roundTripAndDelete() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let now = Date()
        let s = session("测试会话", date: now)
        store.save(s)
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "测试会话")
        #expect(loaded.first?.lines.first?.text == "你好")
        #expect(loaded.first?.answers.first?.text == "你好。")
        store.delete(s.id)
        #expect(store.load().isEmpty)
    }

    @Test func sortsNewestFirstAndTrims() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, maxSessions: 2)
        let base = Date()
        for i in 0..<3 {
            store.save(session("s\(i)", date: base.addingTimeInterval(Double(i))))
        }
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded.map(\.title) == ["s2", "s1"])
    }

    @Test func clearRemovesAll() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        store.save(session("a", date: Date()))
        store.clear()
        #expect(store.load().isEmpty)
    }

    @Test func titleFallsBackToTime() {
        let t = HistorySession.makeTitle(lines: [], date: Date(timeIntervalSince1970: 0))
        #expect(t.hasPrefix("对话 "))
    }
}
