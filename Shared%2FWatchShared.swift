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

    static let diagKey = "watch.diag"

    /// 扩展的运行状态：主 App 读它来判断到底卡在哪一步（没起来 / 读不到配置 / 请求失败）。
    struct Diag: Codable {
        /// 扩展最近一次写入心跳的 Unix 秒。
        var heartbeat: Double = 0
        /// 收到的视频帧数。
        var frames: Int = 0
        /// 真正发出去识别的次数。
        var sent: Int = 0
        /// 扩展自己判断的 App Group 可用性。
        var groupOK = false
        /// 读到的配置里 enabled 是否为 true。
        var configEnabled = false
        var lastError = ""
    }

    /// App Group 是否可用。重签时没给两个 target 都加 entitlements，这里就是 false。
    static var groupAvailable: Bool { UserDefaults(suiteName: suiteName) != nil }

    /// 主 App 与扩展各自跑一遍：往共享域写一个时间戳再读回来。
    /// 返回 "ok" 表示这个进程确实能读写共享容器；"no-suite" 表示连 suite 都拿不到；
    /// "mismatch" 表示写进去读不回来（重签时 group 只给了一边，两个进程各写各的）。
    static func groupProbe() -> String {
        let key = "watch.probe"
        guard UserDefaults(suiteName: suiteName) != nil else { return "no-suite" }
        let stamp = String(Date().timeIntervalSince1970)
        defaults.set(stamp, forKey: key)
        let back = defaults.string(forKey: key) ?? "nil"
        return back == stamp ? "ok" : "mismatch"
    }

    /// 当前进程看到的 App Group 容器路径；"nil" 说明这个进程没有 App Group 权限。
    static var containerPath: String { containerURL?.path ?? "nil" }

    /// 给用户看的容器诊断摘要（App 与扩展都用它，方便对照）。
    static func containerDiagnostics() -> String {
        "路径=\(containerPath)；自检=\(groupProbe())"
    }

    static func readDiag() -> Diag {
        guard let data = defaults.data(forKey: diagKey),
              let diag = try? JSONDecoder().decode(Diag.self, from: data) else {
            return Diag()
        }
        return diag
    }

    static func updateDiag(_ mutate: (inout Diag) -> Void) {
        var diag = readDiag()
        mutate(&diag)
        diag.heartbeat = Date().timeIntervalSince1970
        if let data = try? JSONEncoder().encode(diag) {
            defaults.set(data, forKey: diagKey)
        }
    }

    static func clearDiag() {
        defaults.removeObject(forKey: diagKey)
    }

    // MARK: - 帧通道（扩展 → 主 App）

    /// App Group 容器的真实路径；没生效时是 nil。
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    private static var framesDirectory: URL? {
        guard let base = containerURL else { return nil }
        let dir = base.appendingPathComponent("frames", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 扩展把一帧 JPEG 落进共享容器，并写一个时间戳；主 App 靠时间戳判断是不是新帧。
    @discardableResult
    static func writeFrame(_ jpeg: Data) -> Bool {
        guard let dir = framesDirectory else { return false }
        let stamp = Date().timeIntervalSince1970
        let image = dir.appendingPathComponent("latest.jpg")
        let meta = dir.appendingPathComponent("latest.stamp")
        do {
            try jpeg.write(to: image, options: .atomic)
            try Data(String(stamp).utf8).write(to: meta, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 主 App 取最新一帧；时间戳不大于 `after` 就返回 nil（没有新帧）。
    static func takeFrame(after lastStamp: Double) -> (jpeg: Data, stamp: Double)? {
        guard let dir = framesDirectory else { return nil }
        let meta = dir.appendingPathComponent("latest.stamp")
        let image = dir.appendingPathComponent("latest.jpg")
        guard let metaData = try? Data(contentsOf: meta),
              let text = String(data: metaData, encoding: .utf8),
              let stamp = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              stamp > lastStamp,
              let jpeg = try? Data(contentsOf: image) else { return nil }
        return (jpeg, stamp)
    }

    /// 停止时清掉残留帧，避免下次启动把旧画面当新帧发出去。
    static func clearFrames() {
        guard let dir = framesDirectory else { return }
        for name in ["latest.jpg", "latest.stamp"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
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
