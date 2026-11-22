import Foundation
import SwiftUI
import UIKit

/// App 的全部状态：会话、模型请求、工具循环、持久化、切后台提醒。
@MainActor
final class AppModel: ObservableObject {

    // MARK: - 持久化状态

    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID

    // MARK: - 设置（UserDefaults / Keychain）

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    @Published var maxRounds: Int {
        didSet { UserDefaults.standard.set(maxRounds, forKey: Keys.maxRounds) }
    }
    @Published var warnBeforeRun: Bool {
        didSet { UserDefaults.standard.set(warnBeforeRun, forKey: Keys.warnBeforeRun) }
    }
    /// 只在设置页点「保存」时写钥匙串。每敲一个字符写一次会在主线程上同步写 Keychain，输入会卡。
    @Published var apiKey: String

    // MARK: - 运行状态

    @Published var isRunning = false
    @Published var streamPreview = ""
    @Published var statusLine = ""
    @Published var errorText: String?
    @Published var showSwitchWarning = false

    private var pendingPrompt: String?
    private var runTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundedDuringRun = false
    /// 本次启动是否已经提示过「别切走」。只放内存，重启 App 后重新提醒一次。
    private var warnedThisLaunch = false
    /// 当前这次运行的标识。被 stop 掉的旧任务收尾时不能改动新任务的状态。
    private var runID = UUID()

    private enum Keys {
        static let baseURL = "dsh.baseURL"
        static let model = "dsh.model"
        static let maxRounds = "dsh.maxRounds"
        static let warnBeforeRun = "dsh.warnBeforeRun"
    }

    // MARK: - 初始化

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Keys.baseURL) ?? "https://api.deepseek.com"
        model = defaults.string(forKey: Keys.model) ?? "deepseek-chat"
        let rounds = defaults.integer(forKey: Keys.maxRounds)
        maxRounds = rounds > 0 ? rounds : 24
        warnBeforeRun = defaults.object(forKey: Keys.warnBeforeRun) as? Bool ?? true
        apiKey = Keychain.loadAPIKey()
        currentSessionID = UUID()

        Workspace.prepare()
        loadSessions()
    }

    // MARK: - 会话

    var currentSession: ChatSession {
        sessions.first(where: { $0.id == currentSessionID }) ?? ChatSession()
    }

    var currentItems: [ChatItem] {
        currentSession.items
    }

    func sessionItems(_ id: UUID) -> [ChatItem] {
        sessions.first(where: { $0.id == id })?.items ?? []
    }

    func newSession() {
        guard !isRunning else { return }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
    }

    func select(_ id: UUID) {
        guard !isRunning, sessions.contains(where: { $0.id == id }) else { return }
        currentSessionID = id
    }

    func deleteSession(_ id: UUID) {
        guard !isRunning else { return }
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty { sessions = [ChatSession()] }
        if !sessions.contains(where: { $0.id == currentSessionID }) {
            currentSessionID = sessions[0].id
        }
        save()
    }

    func clearCurrent() {
        guard !isRunning else { return }
        mutate(currentSessionID) { $0.items.removeAll() }
    }

    // MARK: - 发送

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "还没填 API key。右上角齿轮 → 填 DeepSeek API key。"
            return
        }

        if warnBeforeRun && !warnedThisLaunch {
            pendingPrompt = prompt
            showSwitchWarning = true
            return
        }
        startRun(prompt: prompt)
    }

    func confirmSwitchWarning() {
        showSwitchWarning = false
        warnedThisLaunch = true
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        startRun(prompt: prompt)
    }

    func cancelSwitchWarning() {
        showSwitchWarning = false
        pendingPrompt = nil
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        statusLine = ""
        streamPreview = ""
        endBackgroundGrace()
    }

    func retry() {
        guard !isRunning else { return }
        let items = currentItems
        guard let lastUser = items.last(where: { $0.role == .user }) else { return }
        startRun(prompt: lastUser.text, appendUserMessage: false)
    }

    // MARK: - 场景变化（切前台/后台）

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if isRunning {
                backgroundedDuringRun = true
                statusLine = "App 已在后台。iOS 只给几十秒，超时任务会被挂起。"
            }
        case .active:
            if isRunning {
                statusLine = "正在运行，请留在本 App。"
            }
        default:
            break
        }
    }

    // MARK: - 主循环

    private func startRun(prompt: String, appendUserMessage: Bool = true) {
        let sessionID = currentSessionID
        errorText = nil
        streamPreview = ""
        statusLine = "准备中…"
        isRunning = true

        mutate(sessionID) { session in
            if appendUserMessage {
                session.items.append(ChatItem(role: .user, text: prompt))
            }
            if session.title == "新会话", let first = session.items.first(where: { $0.role == .user }) {
                session.title = String(first.text.prefix(20))
            }
        }

        beginBackgroundGrace()
        let id = UUID()
        runID = id
        runTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runLoop(sessionID: sessionID, runID: id)
        }
    }

    private func runLoop(sessionID: UUID, runID myID: UUID) async {
        var round = 0
        var finishedNaturally = false
        while isRunning && runID == myID && round < maxRounds {
            round += 1
            statusLine = "第 \(round) 轮 · 模型思考中…"
            do {
                let turn = try await performChat(sessionID: sessionID)
                streamPreview = ""

                let hasText = !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasText || !turn.toolCalls.isEmpty {
                    mutate(sessionID) { session in
                        session.items.append(ChatItem(role: .assistant,
                                                      text: turn.text,
                                                      toolCalls: turn.toolCalls))
                    }
                }

                if turn.toolCalls.isEmpty {
                    if !hasText {
                        mutate(sessionID) { session in
                            session.items.append(ChatItem(role: .assistant, text: "（模型这轮没有返回内容）"))
                        }
                    }
                    finishedNaturally = true
                    break
                }

                var returned: Set<String> = []
                for call in turn.toolCalls {
                    if !isRunning || runID != myID { break }
                    statusLine = "执行工具 \(call.name)…"
                    let result = await Tools.execute(name: call.name, arguments: call.arguments)
                    returned.insert(call.id)
                    let failed = result.hasPrefix("错误：")
                    mutate(sessionID) { session in
                        session.items.append(ChatItem(role: .tool,
                                                      text: result,
                                                      toolCallId: call.id,
                                                      toolName: call.name,
                                                      isError: failed))
                    }
                }

                // 被停止时剩余的 tool_call 也要补一条结果，否则下一次请求会因
                // tool_calls 和 tool 消息不对应被 DeepSeek 拒绝，这个会话就废了。
                if !isRunning || runID != myID {
                    let missing = turn.toolCalls.filter { !returned.contains($0.id) }
                    for call in missing {
                        mutate(sessionID) { session in
                            session.items.append(ChatItem(role: .tool,
                                                          text: "错误：用户已停止任务，这个工具没有执行。",
                                                          toolCallId: call.id,
                                                          toolName: call.name,
                                                          isError: true))
                        }
                    }
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                let message = describe(error)
                if !message.isEmpty {
                    errorText = message
                    mutate(sessionID) { session in
                        session.items.append(ChatItem(role: .assistant, text: message, isError: true))
                    }
                }
                break
            }
        }

        if !finishedNaturally && round >= maxRounds && isRunning && runID == myID {
            let note = "已经跑了 \(maxRounds) 轮工具，先停在这里。要继续的话再发一条消息。"
            mutate(sessionID) { session in
                session.items.append(ChatItem(role: .assistant, text: note))
            }
        }

        // 被 stop 之后又开了新任务时，旧任务不能把新任务的状态清掉。
        guard runID == myID else { return }
        streamPreview = ""
        statusLine = ""
        isRunning = false
        runTask = nil
        endBackgroundGrace()
        save()
    }

    // MARK: - 模型请求（SSE 流式）

    private func performChat(sessionID: UUID) async throws -> AssistantTurn {
        let body = ChatRequest(model: model,
                               messages: wireMessages(sessionID: sessionID),
                               tools: Tools.specs,
                               tool_choice: "auto",
                               stream: true)

        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            let text = String(data: raw, encoding: .utf8) ?? ""
            throw ToolFailure.message("DeepSeek 返回 HTTP \(http.statusCode)：\n" + Tools.clip(text))
        }

        var text = ""
        var builders: [Int: (id: String, name: String, args: String)] = [:]

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices?.first,
                  let delta = choice.delta
            else { continue }

            if let piece = delta.content, !piece.isEmpty {
                text += piece
                streamPreview = text
            }

            if let calls = delta.tool_calls {
                for call in calls {
                    let index = call.index ?? builders.count
                    var builder = builders[index] ?? (id: "", name: "", args: "")
                    if let id = call.id, !id.isEmpty { builder.id = id }
                    if let function = call.function {
                        if let name = function.name, !name.isEmpty { builder.name = name }
                        if let arguments = function.arguments { builder.args += arguments }
                    }
                    builders[index] = builder
                }
            }
        }

        let toolCalls: [ToolCall] = builders.keys.sorted().compactMap { key in
            guard let builder = builders[key], !builder.name.isEmpty else { return nil }
            return ToolCall(id: builder.id.isEmpty ? UUID().uuidString : builder.id,
                            name: builder.name,
                            arguments: builder.args.isEmpty ? "{}" : builder.args)
        }

        return AssistantTurn(text: text, toolCalls: toolCalls)
    }

    private func endpointURL() throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://api.deepseek.com" }
        if !(base.lowercased().hasPrefix("http://") || base.lowercased().hasPrefix("https://")) {
            base = "https://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base) else {
            throw ToolFailure.message("接口地址不合法：\(base)")
        }
        return url
    }

    private func wireMessages(sessionID: UUID) -> [WireMessage] {
        var out: [WireMessage] = [WireMessage(role: "system", content: systemPrompt())]
        let items = sessions.first(where: { $0.id == sessionID })?.items ?? []
        for item in items {
            switch item.role {
            case .user:
                out.append(WireMessage(role: "user", content: item.text))
            case .assistant:
                let calls = item.toolCalls.map { call in
                    WireToolCall(id: call.id,
                                 type: "function",
                                 function: WireFunction(name: call.name, arguments: call.arguments))
                }
                out.append(WireMessage(role: "assistant",
                                       content: item.text.isEmpty ? nil : item.text,
                                       tool_calls: calls.isEmpty ? nil : calls))
            case .tool:
                out.append(WireMessage(role: "tool",
                                       content: item.text,
                                       tool_call_id: item.toolCallId ?? ""))
            }
        }
        return out
    }

    private func systemPrompt() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        let now = formatter.string(from: Date())

        return """
        你是运行在 iPad 上的 DSH 助手。你身边没有电脑：模型调用、工具执行、文件都在这一台 iPad 上完成。

        可用工具（都在 App 的沙盒工作目录里工作）：
        - list_dir / read_file / write_file / make_dir / delete_path / move_path：读写工作目录里的文件
        - fetch_url：抓取一个 http/https 网页的正文
        - run_js：在 JavaScriptCore 里跑 JS，用 console.log 看输出（适合算数、处理文本）
        - now：当前时间

        规则：
        1. 没有 shell、没有 git、没有编译器和解释器命令行；需要算或处理文本就用 run_js，需要查资料就用 fetch_url。
        2. 路径都相对工作目录，不要写绝对路径。
        3. 多步任务直接动手用工具做，不要只给用户操作步骤。
        4. 工具返回以「错误：」开头表示失败，先看清原因再换办法，别原样重试。
        5. 回答用简洁中文，先说结果再说细节；不要吹牛，做不到就直说。

        现在时间：\(now)
        """
    }

    // MARK: - 错误描述

    private func describe(_ error: Error) -> String {
        if backgroundedDuringRun {
            backgroundedDuringRun = false
            return "任务中断：刚才 App 在后台被 iPadOS 挂起了，网络请求被切断。要继续请留在本 App 再发一条消息。"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return "网络断了，检查一下 Wi-Fi。"
            case .timedOut: return "请求超时。"
            case .cancelled: return "请求被取消了。"
            case .cannotFindHost, .dnsLookupFailed: return "找不到接口域名，检查接口地址。"
            default: return "网络错误：\(urlError.localizedDescription)"
            }
        }
        if let failure = error as? ToolFailure, case .message(let text) = failure {
            return text
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: - 后台宽限

    private func beginBackgroundGrace() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "dsh-turn") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundGrace()
            }
        }
    }

    private func endBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - 持久化

    private var storeURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    private func mutate(_ sessionID: UUID, _ body: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        body(&sessions[index])
        sessions[index].updatedAt = Date()
        save()
    }

    private func loadSessions() {
        if let data = try? Data(contentsOf: storeURL) {
            if let decoded = try? JSONDecoder().decode([ChatSession].self, from: data), !decoded.isEmpty {
                sessions = decoded
                currentSessionID = decoded[0].id
                return
            }
            // 解不开也不能直接覆盖掉：先留一份备份，下次 save() 才不会把历史抹掉。
            let backup = storeURL.deletingPathExtension().appendingPathExtension("bak.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
        }
        let session = ChatSession()
        sessions = [session]
        currentSessionID = session.id
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
