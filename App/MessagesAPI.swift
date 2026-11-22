import Foundation

/// DeepSeek Messages API（Anthropic 兼容协议）的请求构造与 SSE 解析。
///
/// 与 DSH 桌面版走同一套协议：`POST {base}/v1/messages`，请求头 `x-api-key` +
/// `anthropic-version: 2023-06-01`，正文用 `thinking`/`output_config.effort` 表达推理等级。
/// 单独成文件是为了让「协议决定正确性」的部分可以脱离 SwiftUI 阅读和修改。
enum MessagesAPI {
    /// 一轮助手输出的累计结果。
    struct Turn {
        var text = ""
        var reasoning = ""
        var signature = ""
        var toolCalls: [ToolCall] = []
        var stopReason = ""
    }

    /// 协议层失败，统一成给用户看的中文。tool 失败用 Tools 里的 ToolFailure，两者都接 LocalizedError。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 一次请求需要的全部输入。
    struct RequestOptions {
        var model: String
        var system: String
        var effort: String
        var maxTokens: Int
        var messages: [[String: Any]]
        var tools: [[String: Any]]
    }

    /// 协议不支持 off 以外的取值时也不能静默降级，所以把合法集合放在这里。
    static let efforts = ["off", "low", "high", "max"]

    /// 拼接 `/messages` 端点；`base` 已经以 `/v1` 结尾时不再重复。
    static func endpoint(base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        if text.hasSuffix("/v1") { return URL(string: text + "/messages") }
        return URL(string: text + "/v1/messages")
    }

    /// `/models` 挂在站点根上，不在 `/v1` 下面，这是服务端的约定。
    static func modelsURL(base: String) -> URL? {
        guard var components = endpoint(base: base).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.path = "/models"
        components.query = nil
        return components.url
    }

    /// 组装请求体。`thinking` 与 `output_config` 必须一起改：关闭推理时不能再带 effort。
    static func body(_ options: RequestOptions) -> Data? {
        var root: [String: Any] = [
            "model": options.model,
            "max_tokens": options.maxTokens,
            "stream": true,
            "messages": options.messages,
            "thinking": ["type": options.effort == "off" ? "disabled" : "enabled"],
        ]
        let system = options.system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { root["system"] = system }
        if options.effort != "off" { root["output_config"] = ["effort": options.effort] }
        if !options.tools.isEmpty { root["tools"] = options.tools }
        return try? JSONSerialization.data(withJSONObject: root, options: [])
    }

    /// 凭据只走请求头，绝不进 URL（URL 会进日志）。
    static func request(url: URL, apiKey: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// 流式解析。回调在读取流的上下文里触发，调用方负责切回主线程。
    static func stream(
        request: URLRequest,
        onText: @escaping (String) -> Void,
        onReasoning: @escaping (String) -> Void
    ) async throws -> Turn {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "服务器没有返回 HTTP 响应。")
        }
        guard http.statusCode == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "DeepSeek 返回 HTTP \(http.statusCode)\(detail.isEmpty ? "" : "：\n\(detail)")")
        }

        var turn = Turn()
        var blocks: [Int: Block] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let data = payload.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                continue
            }
            switch event["type"] as? String {
            case "error":
                let inner = event["error"] as? [String: Any]
                let message = (inner?["message"] as? String) ?? payload
                throw Failure(message: "DeepSeek 返回错误：\(message)")
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { break }
                blocks[index] = Block(kind: block["type"] as? String ?? "", block: block)
                if let started = blocks[index], started.kind == "text", let text = block["text"] as? String, !text.isEmpty {
                    turn.text += text
                    onText(text)
                }
                if let started = blocks[index], started.kind == "thinking", let text = block["thinking"] as? String, !text.isEmpty {
                    turn.reasoning += text
                    onReasoning(text)
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int, var block = blocks[index],
                      let delta = event["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        block.text += text
                        turn.text += text
                        onText(text)
                    }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String {
                        block.text += text
                        turn.reasoning += text
                        onReasoning(text)
                    }
                case "signature_delta":
                    if let signature = delta["signature"] as? String {
                        block.signature += signature
                        turn.signature += signature
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String { block.arguments += partial }
                default:
                    break
                }
                blocks[index] = block
            case "content_block_stop":
                guard let index = event["index"] as? Int, let block = blocks[index] else { break }
                if block.kind == "tool_use" {
                    var arguments = block.arguments
                    if arguments.isEmpty { arguments = "{}" }
                    turn.toolCalls.append(ToolCall(id: block.id, name: block.name, arguments: arguments))
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    turn.stopReason = reason
                }
            case "message_stop":
                return turn
            default:
                break
            }
        }
        if turn.text.isEmpty && turn.toolCalls.isEmpty && turn.reasoning.isEmpty {
            throw Failure(message: "流在返回任何内容前就结束了。")
        }
        return turn
    }

    /// 一个内容块的累计状态：文本块用 text，工具块用 arguments（JSON 片段）。
    struct Block {
        var kind: String
        var text = ""
        var signature = ""
        var arguments = ""
        var id = ""
        var name = ""

        init(kind: String, block: [String: Any]) {
            self.kind = kind
            if let text = block["text"] as? String { self.text = text }
            if let thinking = block["thinking"] as? String { self.text = thinking }
            if let signature = block["signature"] as? String { self.signature = signature }
            if let id = block["id"] as? String { self.id = id }
            if let name = block["name"] as? String { self.name = name }
        }
    }
}
