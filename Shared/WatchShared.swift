import Foundation

/// 主 App 与屏幕广播扩展共用的配置。
///
/// 两个进程唯一的交汇点是 App Group 容器（`group.com.dsh.qc`）：
/// 主 App 把配置和 API key 写进去，扩展每次截帧前读出来。
enum WatchShared {
    /// 必须与两个 target 的 entitlement、以及用户重签时填的 App Group 完全一致。
    static let suiteName = "group.com.dsh.qc"
    static let configKey = "watch.config"
    static let lastResultKey = "watch.lastResult"
    static let lastResultAtKey = "watch.lastResultAt"
    static let extensionBundleID = "com.dsh.qc.broadcast"

    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    struct Config: Codable {
        /// 主 App 保存时把钥匙串里的 key 复制一份过来 —— 扩展读不到钥匙串。
        var apiKey = ""
        var baseURL = "https://api.deepseek.com/anthropic"
        var model = "deepseek-flash"
        /// off / low / high / max，默认关掉推理（截屏识别不需要思考）。
        var effort = "off"
        var prompt = "看这张屏幕截图，用一句中文说清楚：屏幕上现在最值得注意的内容是什么？"
        /// 1~5 秒一帧。
        var intervalSeconds = 3.0
        var enabled = false
        var notify = true
    }

    static func load() -> Config {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    static func save(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    static func recordResult(_ text: String) {
        defaults.set(text, forKey: lastResultKey)
        defaults.set(Date().timeIntervalSince1970, forKey: lastResultAtKey)
    }

    static func lastResult() -> (text: String, at: Date?)? {
        guard let text = defaults.string(forKey: lastResultKey) else { return nil }
        let stamp = defaults.double(forKey: lastResultAtKey)
        return (text, stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil)
    }
}

/// 截帧识别用的最小 Messages API 客户端（扩展现程里跑，不依赖主 App 的 MessagesAPI）。
enum WatchVision {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func endpoint(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") { trimmed += "/messages" } else { trimmed += "/v1/messages" }
        return URL(string: trimmed)
    }

    static func requestBody(jpegBase64: String, config: WatchShared.Config) -> Data? {
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": 512,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpegBase64]],
                        ["type": "text", "text": config.prompt]
                    ]
                ]
            ]
        ]
        if config.effort == "off" {
            body["thinking"] = ["type": "disabled"]
        } else {
            body["thinking"] = ["type": "enabled"]
            body["output_config"] = ["effort": config.effort]
        }
        return try? JSONSerialization.data(withJSONObject: body)
    }

    static func ask(jpegBase64: String, config: WatchShared.Config) async throws -> String {
        guard !config.apiKey.isEmpty else { throw Failure(message: "还没填 API key（在主 App 设置里填一次）") }
        guard let url = endpoint(base: config.baseURL) else { throw Failure(message: "接口地址不对：\(config.baseURL)") }
        guard let body = requestBody(jpegBase64: jpegBase64, config: config) else { throw Failure(message: "请求体组装失败") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Failure(message: "DeepSeek 返回 HTTP \(http.statusCode)：\(text.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]] else {
            throw Failure(message: "返回内容解析失败")
        }
        var parts: [String] = []
        for block in blocks {
            if let type = block["type"] as? String, type == "text", let text = block["text"] as? String {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { throw Failure(message: "模型没有返回文字") }
        return joined
    }
}
