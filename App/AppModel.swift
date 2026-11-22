import Foundation
import UIKit

/// 可选模型。
struct ModelOption: Identifiable, Hashable {
    var id: String
    var name: String
}

/// 会话与运行的唯一状态源。
///
/// 传输走 Messages API（见 `MessagesAPI`），工具在本机执行，所有会话历史落在
/// `Documents/sessions.json`，工作目录是 `Documents/workspace`。
@MainActor
final class AppModel: ObservableObject {
    // MARK: - 会话

    @Published var sessions: [ChatSession] = []
    @Published var currentSessionID: UUID

    // MARK: - 设置

    /// 接口地址。默认就是 DSH 桌面版用的 Messages 端点根。
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    /// 推理等级：off / low / high / max，与 DSH 的 reasoningEffort 同名同义。
    @Published var reasoningEffort: String {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: Keys.effort) }
    }
    @Published var maxRounds: Int {
        didSet { UserDefaults.standard.set(maxRounds, forKey: Keys.maxRounds) }
    }
    @Published var warnBeforeRun: Bool {
        didSet { UserDefaults.standard.set(warnBeforeRun, forKey: Keys.warnBeforeRun) }
    }
    /// 只在设置页点「保存」时写钥匙串，输入过程中不落盘。
    @Published var apiKey: String

    // MARK: - 运行状态

    @Published var isRunning = false
    @Published var streamPreview = ""
    @Published var reasoningPreview = ""
    @Published var statusLine = ""
    @Published var errorText: String?
    @Published var showSwitchWarning = false
    @Published var availableModels: [ModelOption] = []
    @Published var isFetchingModels = false

    private var pendingPrompt: String?
    private var runTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundedDuringRun = false
    /// 只放内存：重启 App 后重新提醒一次。
    private var warnedThisLaunch = false
    /// 被 stop 的旧任务收尾时不能改动新任务的状态。
    private var runID = UUID()

    private enum Keys {
        static let baseURL = "dsh.baseURL"
        static let model = "dsh.model"
        static let effort = "dsh.effort"
        static let maxRounds = "dsh.maxRounds"
        static let warnBeforeRun = "dsh.warnBeforeRun"
    }

    // MARK: - 生命周期

    init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Keys.baseURL) ?? "https://api.deepseek.com/anthropic"
        model = defaults.string(forKey: Keys.model) ?? "deepseek-flash"
        reasoningEffort = defaults.string(forKey: Keys.effort) ?? "high"
        let rounds = defaults.integer(forKey: Keys.maxRounds)
        maxRounds = rounds > 0 ? rounds : 24
        warnBeforeRun = defaults.object(forKey: Keys.warnBeforeRun) as? Bool ?? true
        apiKey = Keychain.loadAPIKey()
        let first = ChatSession(title: SessionMode.work.title, mode: .work)
        sessions = [first]
        currentSessionID = first.id
        Workspace.prepare()
        PluginHost.shared.reload()
        loadSessions()
    }

    // MARK: - 会话操作

    var currentSession: ChatSession? {
        sessions.first { $0.id == currentSessionID }
    }

    var currentItems: [ChatItem] {
        currentSession?.items ?? []
    }

    func newSession() {
        newSession(mode: .work)
    }

    /// 新建会话。对话模式不加载工具、不弹「别切走」；工作模式才允许改文件。
    func newSession(mode: SessionMode) {
        guard !isRunning else { return }
        let session = ChatSession(title: mode.title, mode: mode)
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        save()
    }

    /// 切换当前会话的模式。运行中不改，免得同一轮里规则前后不一致。
    func setMode(_ mode: SessionMode) {
        guard !isRunning else { return }
        mutate(currentSessionID) { session in
            guard session.mode != mode else { return }
            session.mode = mode
            if session.title == SessionMode.chat.title || session.title == SessionMode.work.title {
                session.title = mode.title
            }
        }
    }

    func select(_ id: UUID) {
        guard !isRunning else { return }
        currentSessionID = id
    }

    func deleteSession(_ id: UUID) {
        guard !isRunning, sessions.count > 1 else { return }
        sessions.removeAll { $0.id == id }
        if currentSessionID == id, let first = sessions.first {
            currentSessionID = first.id
        }
        save()
    }

    func clearCurrent() {
        guard !isRunning else { return }
        mutate(currentSessionID) { $0.items = [] }
    }

    // MARK: - 发送与任务循环

    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        var problem: String?
        if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            problem = "还没填 API key。到设置里填一个，保存后再发。"
        } else if MessagesAPI.endpoint(base: baseURL) == nil {
            problem = "接口地址不可用：\(baseURL)"
        }
        if let problem {
            errorText = problem
            return
        }
        if currentSession?.mode == .work, warnBeforeRun, !warnedThisLaunch {
            pendingPrompt = text
            showSwitchWarning = true
            return
        }
        startRun(prompt: text, appendUserMessage: true)
    }

    func confirmSwitchWarning() {
        showSwitchWarning = false
        warnedThisLaunch = true
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        startRun(prompt: prompt, appendUserMessage: true)
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
        reasoningPreview = ""
        endBackgroundGrace()
    }

    func retry() {
        guard !isRunning else { return }
        let lastUser = currentItems.last { $0.role == .user }
        guard let prompt = lastUser?.text else { return }
        mutate(currentSessionID) { session in
            while let last = session.items.last, last.role != .user {
                session.items.removeLast()
            }
            if let last = session.items.last, last.role == .user {
                session.items.removeLast()
            }
        }
        startRun(prompt: prompt, appendUserMessage: true)
    }

    func handleScenePhase(_ phase: ScenePhaseValue) {
        switch phase {
        case .active:
            if backgroundedDuringRun && isRunning {
                statusLine = "App 刚从后台回来，这一轮可能已经断了。"
            }
            backgroundedDuringRun = false
        case .background, .inactive:
            if isRunning { backgroundedDuringRun = true }
        }
    }

    private func startRun(prompt: String, appendUserMessage: Bool) {
        let sessionID = currentSessionID
        if appendUserMessage {
            appendItem(ChatItem(role: .user, text: prompt), to: sessionID)
        }
        errorText = nil
        isRunning = true
        statusLine = "正在思考…"
        streamPreview = ""
        reasoningPreview = ""
        beginBackgroundGrace()
        let id = UUID()
        runID = id
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(sessionID: sessionID, runID: id)
        }
    }

    private func runLoop(sessionID: UUID, runID myID: UUID) async {
        var round = 0
        var finishedNaturally = false

        while isRunning, runID == myID, round < maxRounds {
            round += 1
            statusLine = currentSession?.mode == .chat ? "正在回答…" : "第 \(round) 轮：正在思考…"
            streamPreview = ""
            reasoningPreview = ""

            let turn: MessagesAPI.Turn
            do {
                turn = try await performChat(sessionID: sessionID)
            } catch is CancellationError {
                break
            } catch {
                guard runID == myID else { return }
                appendItem(ChatItem(role: .assistant, text: describe(error), isError: true), to: sessionID)
                break
            }

            let assistantItem = ChatItem(
                role: .assistant,
                text: turn.text,
                toolCalls: turn.toolCalls,
                reasoning: turn.reasoning.isEmpty ? nil : turn.reasoning,
                reasoningSignature: turn.signature.isEmpty ? nil : turn.signature
            )
            appendItem(assistantItem, to: sessionID)
            streamPreview = ""

            if turn.toolCalls.isEmpty {
                finishedNaturally = true
                break
            }

            var returned: Set<String> = []
            for call in turn.toolCalls {
                if !isRunning || runID != myID { break }
                statusLine = "正在执行 \(call.name)…"
                let output = await executeTool(name: call.name, arguments: call.arguments)
                appendItem(
                    ChatItem(
                        role: .tool,
                        text: output,
                        toolCallId: call.id,
                        toolName: call.name,
                        isError: output.hasPrefix("错误：")
                    ),
                    to: sessionID
                )
                returned.insert(call.id)
            }

            if !isRunning || runID != myID {
                let missing = turn.toolCalls.filter { !returned.contains($0.id) }
                if !missing.isEmpty {
                    for call in missing {
                        appendItem(
                            ChatItem(
                                role: .tool,
                                text: "错误：用户已停止任务，这个工具没有执行。",
                                toolCallId: call.id,
                                toolName: call.name,
                                isError: true
                            ),
                            to: sessionID
                        )
                    }
                }
                break
            }
        }

        if !finishedNaturally && round >= maxRounds && isRunning && runID == myID {
            appendItem(
                ChatItem(
                    role: .assistant,
                    text: "已经跑了 \(maxRounds) 轮工具，先停在这里。要接着做就再发一句话。",
                    isError: true
                ),
                to: sessionID
            )
        }

        guard runID == myID else { return }
        streamPreview = ""
        reasoningPreview = ""
        statusLine = ""
        isRunning = false
        runTask = nil
        endBackgroundGrace()
        save()
    }

    // MARK: - 网络

    private func performChat(sessionID: UUID) async throws -> MessagesAPI.Turn {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw MessagesAPI.Failure(message: "没有 API key。")
        }
        guard let url = MessagesAPI.endpoint(base: baseURL) else {
            throw MessagesAPI.Failure(message: "接口地址不合法：\(baseURL)")
        }
        let options = MessagesAPI.RequestOptions(
            model: model,
            system: systemPrompt(sessionID: sessionID),
            effort: reasoningEffort,
            maxTokens: 8192,
            messages: wireMessages(sessionID: sessionID),
            tools: wireTools(sessionID: sessionID)
        )
        guard let payload = MessagesAPI.body(options) else {
            throw MessagesAPI.Failure(message: "请求体无法编码成 JSON。")
        }
        let request = MessagesAPI.request(url: url, apiKey: key, body: payload)
        return try await MessagesAPI.stream(
            request: request,
            onText: { delta in
                Task { @MainActor [weak self] in self?.streamPreview += delta }
            },
            onReasoning: { delta in
                Task { @MainActor [weak self] in self?.reasoningPreview += delta }
            }
        )
    }

    /// 从 `/models` 拉模型列表；失败只提示，不改当前选择。
    func fetchModels() async {
        guard let url = MessagesAPI.modelsURL(base: baseURL) else {
            errorText = "接口地址不合法，没法拉模型列表。"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw MessagesAPI.Failure(message: "拉模型列表失败：HTTP \(code)")
            }
            availableModels = Self.parseModels(data)
            if availableModels.isEmpty {
                throw MessagesAPI.Failure(message: "接口没返回任何模型。")
            }
            if !availableModels.contains(where: { $0.id == model }), let first = availableModels.first {
                model = first.id
            }
        } catch {
            errorText = describe(error)
        }
    }

    static func parseModels(_ data: Data) -> [ModelOption] {
        let object = (try? JSONSerialization.jsonObject(with: data, options: []))
        var entries: [[String: Any]] = []
        if let root = object as? [String: Any] {
            entries = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) ?? []
        } else if let root = object as? [[String: Any]] {
            entries = root
        }
        var options: [ModelOption] = []
        for entry in entries {
            guard let id = entry["id"] as? String ?? entry["name"] as? String, !id.isEmpty else { continue }
            let name = (entry["display_name"] as? String) ?? (entry["name"] as? String) ?? id
            options.append(ModelOption(id: id, name: name))
        }
        return options
    }

    // MARK: - 请求组装

    /// 插件工具优先：插件注册的名字与内置工具重名时插件会被改名，所以不会撞。
    private func executeTool(name: String, arguments: String) async -> String {
        if PluginHost.shared.hasTool(name) {
            do {
                return try await PluginHost.shared.call(name: name, arguments: arguments)
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return "错误：\(text)"
            }
        }
        return await Tools.execute(name: name, arguments: arguments)
    }

    private func wireTools(sessionID: UUID) -> [[String: Any]] {
        // 对话模式一个工具都不给：模型拿不到工具就没法动文件，也不会长出长循环。
        guard sessions.first(where: { $0.id == sessionID })?.mode != .chat else { return [] }
        return (Tools.specs + PluginHost.shared.toolSpecs()).map { spec in
            var properties: [String: Any] = [:]
            for (key, value) in spec.function.parameters.properties {
                properties[key] = ["type": value.type, "description": value.description]
            }
            let schema: [String: Any] = [
                "type": "object",
                "properties": properties,
                "required": spec.function.parameters.required,
            ]
            return [
                "name": spec.function.name,
                "description": spec.function.description,
                "input_schema": schema,
            ]
        }
    }

    /// 会话历史 → Messages API 的 messages 数组。
    ///
    /// 三条硬约定：tool_result 必须放在 user 消息里且紧跟对应 tool_use；
    /// 连续同角色消息合并；thinking 只在带签名时回放（没有签名服务端会拒），
    /// 推理关闭时不回放任何 thinking 块。
    private func wireMessages(sessionID: UUID) -> [[String: Any]] {
        let items = sessions.first { $0.id == sessionID }?.items ?? []
        var messages: [[String: Any]] = []
        var pendingResults: [[String: Any]] = []

        func flushResults() {
            guard !pendingResults.isEmpty else { return }
            messages.append(["role": "user", "content": pendingResults])
            pendingResults = []
        }

        func appendText(role: String, text: String) {
            guard !text.isEmpty else { return }
            let block: [String: Any] = ["type": "text", "text": text]
            if var last = messages.last, (last["role"] as? String) == role,
               let existing = last["content"] as? [[String: Any]],
               existing.allSatisfy({ ($0["type"] as? String) == "text" }) {
                var blocks = existing
                blocks.append(block)
                last["content"] = blocks
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": [block]])
            }
        }

        for item in items {
            switch item.role {
            case .user:
                flushResults()
                appendText(role: "user", text: item.text)
            case .assistant:
                flushResults()
                var blocks: [[String: Any]] = []
                if reasoningEffort != "off", let reasoning = item.reasoning, let signature = item.reasoningSignature, !signature.isEmpty {
                    blocks.append(["type": "thinking", "thinking": reasoning, "signature": signature])
                }
                if !item.text.isEmpty {
                    blocks.append(["type": "text", "text": item.text])
                }
                for call in item.toolCalls {
                    let input: Any = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8), options: [])) ?? [:]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                if !blocks.isEmpty {
                    messages.append(["role": "assistant", "content": blocks])
                }
            case .tool:
                let text = item.text.isEmpty ? "（没有输出）" : item.text
                var block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": item.toolCallId ?? "",
                    "content": [["type": "text", "text": text]],
                ]
                if item.isError { block["is_error"] = true }
                pendingResults.append(block)
            }
        }
        flushResults()
        return messages
    }

    private func systemPrompt(sessionID: UUID) -> String {
        let isChat = sessions.first(where: { $0.id == sessionID })?.mode != .work
        if isChat {
            return """
            你是运行在 iPad 上的 DeepSeek Harness 客户端里的助手。

            当前会话模式：「对话」模式。这一点以本段为准 —— 历史消息里如果提到别的模式，那是切换模式之前的旧说法，已作废。

            对话模式没有工具：你看不到这台设备上的文件，也没有 shell，不能执行任何命令。需要时直接说明你做不到，不要假装调用过工具。用户要你改文件或看文件时，提醒他把会话切到「工作」模式（顶部模式胶囊）。被问到「你现在是什么模式」时，回答「对话模式」。

            行为准则：
            - 回答用中文，直接给结论，不要客套。
            - 需要查资料就说明你知道什么、不确定什么。

            当前时间：\(nowString())
            """
        }
        let mountNames = MountStore.shared.mounts.map { $0.name }
        let mountLine: String
        if mountNames.isEmpty {
            mountLine = "- 除了工作目录，还可以访问用户在设置里手动授权的外部文件夹（现在还没授权任何文件夹）。"
        } else {
            mountLine = "- 已授权的外部文件夹：" + mountNames.joined(separator: "、") + "，用 `mount:<名字>/子路径` 访问，例如 mount:" + (mountNames.first ?? "名字") + "/清单.txt。"
        }
        return """
        你是运行在 iPad 上的 DeepSeek Harness 客户端里的助手。模型调用走 DeepSeek API，工具和文件都在本机执行。

        当前会话模式：「工作」模式，工具已启用，可以真的读写文件、跑工具循环。这一点以本段为准 —— 历史消息里如果提到「对话模式」「没有工具」，那是切换模式之前的旧说法，已作废。被问到「你现在是什么模式」时，回答「工作模式」。

        环境限制（不要假装能绕过）：
        - 这是 iOS App，没有 shell、没有 git、没有编译器，不能 fork 进程，也不能读写系统目录或别的 App 的私有数据。
        - 文件路径相对工作目录（Documents/workspace），也可以用 mount:<名字>/... 访问用户在设置里授权的文件夹。
        \(mountLine)
        - 需要计算或脚本时用 run_js；需要取网页内容时用 fetch_url。

        可用工具：list_dir / read_file / write_file / edit_file / make_dir / delete_path / move_path / copy_path / search_files / file_info / fetch_url / run_js / now。

        改文件先用 read_file 看原文，再用 edit_file 按原文替换；整篇重写才用 write_file。找不到东西就用 search_files 搜。

        行为准则：
        - 回答用中文，直接给结论和步骤，不要客套。
        - 工具返回以「错误：」开头表示失败，不要当作正常结果继续编造。
        - 长任务先给一句计划，再动手。

        当前时间：\(nowString())
        """
    }

    private func nowString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: Date())
    }

    private func describe(_ error: Error) -> String {
        if backgroundedDuringRun {
            backgroundedDuringRun = false
            return "任务中断：刚才 App 在后台被 iPadOS 挂起，网络连接被切断了。回来重发一次。"
        }
        if let failure = error as? MessagesAPI.Failure { return failure.message }
        if let failure = error as? LocalizedError, let text = failure.errorDescription { return text }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "没有网络连接。"
            case NSURLErrorTimedOut: return "请求超时，再试一次。"
            case NSURLErrorCancelled: return "请求被取消。"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "找不到服务器：\(baseURL)"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "HTTPS 证书校验失败。"
            default: break
            }
        }
        return ns.localizedDescription
    }

    // MARK: - 后台宽限

    private func beginBackgroundGrace() {
        endBackgroundGrace()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "dsh-turn") { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
    }

    private func endBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - 持久化

    private var storeURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions.json")
    }

    private func appendItem(_ item: ChatItem, to sessionID: UUID) {
        mutate(sessionID) { session in
            session.items.append(item)
            if item.role == .user, session.title == "新会话" {
                session.title = String(item.text.prefix(18))
            }
        }
    }

    private func mutate(_ sessionID: UUID, _ body: (inout ChatSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        body(&sessions[index])
        sessions[index].updatedAt = Date()
        save()
    }

    private func loadSessions() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode([ChatSession].self, from: data)
            if decoded.isEmpty { return }
            sessions = decoded
            currentSessionID = decoded[0].id
        } catch {
            // 解码失败时先备份，避免下一次 save 把历史覆盖成空。
            let backup = storeURL.deletingLastPathComponent().appendingPathComponent("sessions.bak.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: storeURL, to: backup)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            errorText = "会话历史保存失败：\(error.localizedDescription)"
        }
    }
}

/// 把 SwiftUI 的 ScenePhase 隔在这里，AppModel 不需要 import SwiftUI。
enum ScenePhaseValue {
    case active
    case inactive
    case background
}
