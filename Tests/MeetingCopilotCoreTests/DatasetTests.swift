import Foundation
import Testing

/// 数据集结构校验：保证评测输入本身是自洽的。
struct DatasetTests {
    @Test func datasetShape() throws {
        let ds = try EvalData.loadDialogs()
        #expect(ds.count >= 40)
        let cats = Set(ds.map(\.category))
        for c in ["think_pause", "multi_question", "half_followup", "imperative", "chitchat", "me_interrupt",
                  "backchannel", "echo", "mixed_lang", "english", "long_technical", "full_interview"] {
            #expect(cats.contains(c), "缺少类别 \(c)")
        }
        #expect(Set(ds.map(\.id)).count == ds.count)
    }

    @Test func annotationsAreConsistent() throws {
        for d in try EvalData.loadDialogs() {
            #expect(!d.expected.isEmpty, "\(d.id) 没有标注")
            for (a, b) in zip(d.expected, d.expected.dropFirst()) {
                #expect(a.windowEnd < b.turnStart, "\(d.id) 的标注窗口重叠")
            }
            for x in d.expected {
                #expect(x.turnStart <= x.questionEnd && x.questionEnd <= x.windowEnd + 1e-9, "\(d.id)/\(x.id) 时间顺序错误")
                #expect(!d.questionSegments(x).isEmpty, "\(d.id)/\(x.id) 找不到对方的话")
            }
            // 同一说话人相邻段间隔 >= 0.8s（否则 VAD 会把它们合并成一段）
            for sp in ["对方", "我"] {
                let ev = d.events.filter { $0.speaker == sp && $0.kind == "speech" }.sorted { $0.start < $1.start }
                for (a, b) in zip(ev, ev.dropFirst()) {
                    #expect(b.start - a.end >= 0.8 - 1e-6, "\(d.id) \(sp) 相邻段间隔过短")
                }
            }
        }
    }

    @Test func audioFixturesMatchManifest() throws {
        let m = try EvalData.loadManifest()
        #expect(m.count == 10)
        let ids = Set(try EvalData.loadDialogs().map(\.id))
        for (id, clip) in m {
            #expect(ids.contains(id))
            #expect(FileManager.default.fileExists(atPath: EvalPaths.audio.appendingPathComponent(clip.file).path))
            #expect(clip.sampleRate == 16000)
        }
    }
}
