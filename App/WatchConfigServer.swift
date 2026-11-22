import Foundation
import Network

/// 主 App 侧的 loopback 配置服务。
///
/// 广播扩展跑在独立进程里，读不到主 App 的沙盒；如果重签时 App Group 没注入到
/// 扩展的 entitlement，共享容器和共享 UserDefaults 在扩展里都是 nil。这条路绕开
/// entitlement：主 App 在前台时把配置挂在一个 127.0.0.1 端口上，扩展启动时过来取。
/// 只绑定 loopback，不监听外部地址，也不需要本地网络权限。
final class WatchConfigServer {

    static let shared = WatchConfigServer()

    /// 只处理 GET /config（返回配置 JSON）和 GET /ping（探活）。
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.dsh.qc.watch.config")
    private var payload: Data?

    private init() {}

    /// 用最新配置启动（已在跑就只换内容，避免端口重开）。
    func serve(_ config: WatchShared.Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.payload = data
            if self.listener != nil { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                                  port: NWEndpoint.Port(rawValue: WatchShared.loopbackPort)!)
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                // 端口被占时静默失败：扩展取不到配置会自己报「拿不到配置」，用户能看到原因。
                self.listener = nil
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.payload = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let error {
                _ = error
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let isConfig = request.hasPrefix("GET /config")
            let isPing = request.hasPrefix("GET /ping")
            let body: Data
            let status: String
            if isConfig, let payload = self.payload {
                body = payload
                status = "HTTP/1.1 200 OK"
            } else if isPing {
                body = Data("ok".utf8)
                status = "HTTP/1.1 200 OK"
            } else {
                body = Data("no config".utf8)
                status = "HTTP/1.1 404 Not Found"
            }
            var head = status + "\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Connection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            _ = isComplete
        }
    }
}
