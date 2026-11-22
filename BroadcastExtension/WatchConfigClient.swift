import Foundation

/// 扩展侧从主 App 的 loopback 服务取配置。
///
/// 为什么不读共享容器：重签时如果只给主 App 注入了 App Group，扩展里
/// `containerURL(forSecurityApplicationGroupIdentifier:)` 直接是 nil，
/// 连共享 UserDefaults 也读不到（实测就是这样）。loopback 不需要任何 entitlement。
enum WatchConfigClient {

    struct Failure: Error {
        let message: String
    }

    private static let timeout: TimeInterval = 1.5
    private static let attempts = 12

    /// 取一次配置；主 App 可能刚进后台还没起服务，所以带重试。
    static func fetch() -> Result<WatchShared.Config, Failure> {
        var lastError = "主 App 的配置服务没响应"
        for index in 1...attempts {
            if let config = tryFetch() { return .success(config) }
            lastError = "第 \(index) 次请求 127.0.0.1:\(WatchShared.loopbackPort)/config 没拿到配置"
            if index < attempts { Thread.sleep(forTimeInterval: 0.8) }
        }
        return .failure(Failure(message: lastError))
    }

    private static func tryFetch() -> WatchShared.Config? {
        guard let url = URL(string: "http://127.0.0.1:\(WatchShared.loopbackPort)/config") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.error = error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                box.error = "HTTP \(response.map { String(describing: ($0 as? HTTPURLResponse)?.statusCode ?? -1) } ?? "nil")"
                return
            }
            box.data = data
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        guard let data = box.data else { return nil }
        return try? JSONDecoder().decode(WatchShared.Config.self, from: data)
    }

    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var error: String?
    }
}
