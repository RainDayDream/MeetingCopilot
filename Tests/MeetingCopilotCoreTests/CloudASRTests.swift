import Foundation
import Testing
@testable import MeetingCopilotCore

struct CloudASRTests {
    @Test func runTaskCarriesModelAndFormat() throws {
        let msg = AliyunParaformerTranscriber.runTask(
            taskID: "task-1",
            model: AliyunParaformerTranscriber.defaultModel,
            languageHints: ["zh"])
        let data = try JSONSerialization.data(withJSONObject: msg)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try #require(obj["header"] as? [String: Any])
        let payload = try #require(obj["payload"] as? [String: Any])
        let params = try #require(payload["parameters"] as? [String: Any])
        #expect(header["action"] as? String == "run-task")
        #expect(header["task_id"] as? String == "task-1")
        #expect(header["streaming"] as? String == "duplex")
        #expect(payload["model"] as? String == "paraformer-realtime-v2")
        #expect(payload["task_group"] as? String == "audio")
        #expect(payload["task"] as? String == "asr")
        #expect(params["format"] as? String == "pcm")
        #expect(params["sample_rate"] as? Int == 16000)
        #expect(params["language_hints"] as? [String] == ["zh"])
    }

    @Test func finishTaskReusesTaskID() throws {
        let msg = AliyunParaformerTranscriber.finishTask(taskID: "task-1")
        let data = try JSONSerialization.data(withJSONObject: msg)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try #require(obj["header"] as? [String: Any])
        #expect(header["action"] as? String == "finish-task")
        #expect(header["task_id"] as? String == "task-1")
    }

    @Test func pcm16IsLittleEndianMono() {
        let data = AliyunParaformerTranscriber.pcm16([0, 1, -1])
        #expect(data.count == 6)
        #expect(Array(data) == [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80])
    }

    @Test func parsesFinalAndPartialResults() throws {
        let final = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你好","sentence_end":true}}}}"#
        let partial = #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"text":"你","sentence_end":false}}}}"#
        let failed = #"{"header":{"event":"task-failed","error_code":"CLIENT_ERROR","error_message":"boom"},"payload":{}}"#
        let f = try #require(AliyunParaformerTranscriber.parseServerEvent(final))
        let p = try #require(AliyunParaformerTranscriber.parseServerEvent(partial))
        let e = try #require(AliyunParaformerTranscriber.parseServerEvent(failed))
        #expect(f.name == "result-generated")
        #expect(f.text == "你好")
        #expect(f.sentenceEnd)
        #expect(p.sentenceEnd == false)
        #expect(e.name == "task-failed")
        #expect(e.error?.contains("boom") == true)
    }

    @Test func missingKeyFailsBeforeOpeningSocket() async {
        let t = AliyunParaformerTranscriber(apiKey: "   ")
        do {
            _ = try await t.transcribe([0.1, 0.2])
            Issue.record("expected missingKey")
        } catch let e as CloudASRError {
            if case .missingKey = e {} else { Issue.record("unexpected error: \(e)") }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
