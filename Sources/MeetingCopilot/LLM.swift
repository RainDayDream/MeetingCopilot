import Foundation

enum LLMError: LocalizedError {
    case badURL(String)
    case insecure
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "API 地址无效：\(s)"
        case .insecure: return "出于安全考虑，非本机地址必须使用 https。"
        case .http(let c, let b): return "API 返回 \(c)：\(b)"
        }
    }
}

enum LLM {
    /// 流式调用大模型，逐段返回文本。只发出一个 HTTPS 请求，不执行任何返回内容。
    static func stream(settings: Settings, apiKey: String, system: String,
                       user: String, imageJPEG: Data?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let req = try makeRequest(settings: settings, apiKey: apiKey,
                                              system: system, user: user, image: imageJPEG)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw LLMError.http(0, "无响应") }
                    if !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await l in bytes.lines { body += l; if body.count > 500 { break } }
                        throw LLMError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let t = parse(provider: settings.provider, payload), !t.isEmpty { cont.yield(t) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func validate(_ base: String) throws -> URL {
        guard let u = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = u.host else { throw LLMError.badURL(base) }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard u.scheme == "https" || (u.scheme == "http" && local) else { throw LLMError.insecure }
        return u
    }

    private static func makeRequest(settings: Settings, apiKey: String, system: String,
                                    user: String, image: Data?) throws -> URLRequest {
        let base = try validate(settings.baseURL)
        var req: URLRequest
        var body: [String: Any]
        let b64 = image?.base64EncodedString()

        switch settings.provider {
        case .openai:
            req = URLRequest(url: base.appendingPathComponent("chat/completions"))
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            // 无图时用纯字符串 content（DeepSeek 等纯文本模型只认这种格式）
            var content: Any = user
            if let b64 {
                content = [["type": "text", "text": user],
                           ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]] as [[String: Any]]
            }
            body = ["model": settings.model, "stream": true,
                    "messages": [["role": "system", "content": system],
                                 ["role": "user", "content": content]]]
        case .anthropic:
            req = URLRequest(url: base.appendingPathComponent("v1/messages"))
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var parts: [[String: Any]] = []
            if let b64 {
                parts.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]])
            }
            parts.append(["type": "text", "text": user])
            body = ["model": settings.model, "max_tokens": 1500, "stream": true, "system": system,
                    "messages": [["role": "user", "content": parts]]]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func parse(provider: Provider, _ payload: String) -> String? {
        guard let d = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        switch provider {
        case .openai:
            let choice = (obj["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            guard obj["type"] as? String == "content_block_delta" else { return nil }
            return (obj["delta"] as? [String: Any])?["text"] as? String
        }
    }
}
