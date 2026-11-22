import Combine
import UniformTypeIdentifiers
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
    /// 卡片底的不透明度：用户嫌壁纸被盖住时可以自己调透。
    @Published var cardOpacity: Double {
        didSet { UserDefaults.standard.set(cardOpacity, forKey: Keys.cardOpacity) }
    }
    /// 输入框里已经选好、还没发出去的图片和文件。
    @Published var pendingAttachments: [AttachmentRef] = []

    // MARK: - 运行状态

    @Published var isRunning = false
    @Published var streamPreview = ""
    @Published var reasoningPreview = ""
    @Published var statusLine = ""
    @Published var errorText: String?
    @Published var showSwitchWarning = false
    /// 长按「修改」把原文塞回输入框；ChatCard 取走后置空。
    static let systemPromptKey = "dsh.systemPromptOverride"

    /// 系统提示词覆盖：用户（或 agent 自己调 app_config）写的内容，非空时整段替换内置提示词。
    @Published var systemPromptOverride: String = ""
    /// 由 AttachmentPanel / SettingsView 置上，RootView 在最高层统一弹系统选择器。
    @Published var pickerRequest: PickerRequest?
    /// 挂载列表变化时 +1，设置页据此重新读 MountStore。
    @Published var mountsVersion = 0

    @Published var draftInjection: String?
    /// 一次性小提示（复制成功之类）。
    @Published var toast: String?
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
    /// send 之后、真正开跑之前（可能中间插了个「别切走」确认框），附件得先存着。
    private var queuedAttachments: [AttachmentRef] = []

    private enum Keys {
        static let baseURL = "dsh.baseURL"
        static let model = "dsh.model"
        static let effort = "dsh.effort"
        static let maxRounds = "dsh.maxRounds"
        static let warnBeforeRun = "dsh.warnBeforeRun"
        static let cardOpacity = "dsh.cardOpacity"
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
        let opacity = defaults.object(forKey: Keys.cardOpacity) as? Double ?? 0.72
        cardOpacity = opacity < 0.15 ? 0.72 : min(opacity, 1.0)
        apiKey = Keychain.loadAPIKey()
        let first = ChatSession(title: SessionMode.work.title, mode: .work)
        sessions = [first]
        currentSessionID = first.id
        Workspace.prepare()
        PluginHost.shared.reload()
        loadSessions()
        systemPromptOverride = UserDefaults.standard.string(forKey: AppModel.systemPromptKey) ?? ""
        NotificationCenter.default.addObserver(forName: Tools.configChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadConfig() }
        }
    }

    /// app_config 工具改完 UserDefaults 后会调这里，把新值同步回界面状态。
    func reloadConfig() {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "dsh.baseURL") { baseURL = value }
        if let value = defaults.string(forKey: "dsh.model") { model = value }
        if let value = defaults.string(forKey: "dsh.effort") { reasoningEffort = value }
        let rounds = defaults.integer(forKey: "dsh.maxRounds")
        if rounds >= 4 { maxRounds = rounds }
        if let warn = defaults.object(forKey: "dsh.warnBeforeRun") as? Bool { warnBeforeRun = warn }
        if let opacity = defaults.object(forKey: "dsh.cardOpacity") as? Double, opacity >= 0.15 {
            cardOpacity = min(opacity, 1.0)
        }
        systemPromptOverride = defaults.string(forKey: AppModel.systemPromptKey) ?? ""
    }

    /// 系统选择器回来之后统一在这里落地：文件夹走授权，文件走附件。
    func handlePicked(_ urls: [URL], folders: Bool) {
        guard !urls.isEmpty else { return }
        if folders {
            for url in urls {
                do {
                    let mount = try MountStore.shared.add(url: url)
                    toast = "已授权文件夹：\(mount.name)"
                } catch {
                    toast = "文件夹没授权上：\(error.localizedDescription)"
                }
            }
            mountsVersion += 1
            return
        }
        for url in urls { addAttachment(from: url) }
    }

    /// 把外部选中的文件读进来（带安全作用域访问 + iCloud 下载兜底）。
    func addAttachment(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            var data = try Data(contentsOf: url)
            if data.isEmpty {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                data = try Data(contentsOf: url)
            }
            let type = UTType(filenameExtension: url.pathExtension)
            let isImage = type?.conforms(to: .image) ?? false
            let ref = try AttachmentStore.shared.save(data: data,
                                                     fileName: url.lastPathComponent,
                                                     mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                                     kind: isImage ? .image : .file)
            pendingAttachments.append(ref)
            toast = "已加入 \(url.lastPathComponent)"
        } catch {
            toast = "文件没加上：\(error.localizedDescription)"
        }
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
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isRunning else { return }
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
        queuedAttachments = attachments
        pendingAttachments = []
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

    /// 把这条用户消息之后的内容全删掉，原文交回输入框让用户改完再发。
    func takeBackPrompt(_ itemID: UUID) -> String? {
        guard !isRunning else { return nil }
        let sessionID = currentSessionID
        var text: String?
        mutate(sessionID) { session in
            guard let index = session.items.firstIndex(where: { $0.id == itemID }) else { return }
            text = session.items[index].text
            session.items.removeSubrange(index..<session.items.endIndex)
        }
        save()
        return text
    }

    /// 重新生成最后一条回复：砍掉最后一次问答，用同一个提问重跑。
    func regenerateLastReply() {
        guard !isRunning else { return }
        let sessionID = currentSessionID
        var prompt: String?
        mutate(sessionID) { session in
            guard let userIndex = session.items.lastIndex(where: { $0.role == .user }) else { return }
            prompt = session.items[userIndex].text
            session.items.removeSubrange((userIndex + 1)..<session.items.endIndex)
        }
        save()
        guard let prompt, !prompt.isEmpty else {
            errorText = "这条提问没有文字内容，没法重新生成。"
            return
        }
        startRun(prompt: prompt, appendUserMessage: false)
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
            let attachments = queuedAttachments
            queuedAttachments = []
            appendItem(ChatItem(role: .user, text: prompt, attachments: attachments), to: sessionID)
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
        let startedAt = Date()
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
        let elapsed = Date().timeIntervalSince(startedAt)
        mutate(sessionID) { $0.lastRunSeconds = elapsed }
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
                if item.attachments.isEmpty {
                    appendText(role: "user", text: item.text)
                } else {
                    var blocks: [[String: Any]] = []
                    for ref in item.attachments {
                        if ref.kind == .image, let data = AttachmentStore.shared.base64(for: ref) {
                            blocks.append([
                                "type": "image",
                                "source": ["type": "base64", "media_type": ref.mimeType, "data": data],
                            ])
                            continue
                        }
                        blocks.append(["type": "text", "text": fileAttachmentNote(ref)])
                    }
                    if !item.text.isEmpty {
                        blocks.append(["type": "text", "text": item.text])
                    }
                    messages.append(["role": "user", "content": blocks])
                }
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

    /// 文件类附件塞不进图片块，只能把「在哪儿、多大」写进文本，让模型自己用工具去读。
    private func fileAttachmentNote(_ ref: AttachmentRef) -> String {
        if let local = mirrorAttachment(ref) {
            return "（用户上传了文件：\(ref.fileName)，\(ref.byteCount) 字节，已复制到工作目录 \(local)，可以用 read_file 读。）"
        }
        return "（用户上传了文件：\(ref.fileName)，\(ref.byteCount) 字节，但复制到工作目录失败，读不到内容。）"
    }

    /// 工具只能访问工作目录与挂载目录，所以把附件副本放进 workspace/attachments 才能被 read_file 读到。
    private func mirrorAttachment(_ ref: AttachmentRef) -> String? {
        guard ref.kind == .file else { return nil }
        let manager = FileManager.default
        let folder = Workspace.root.appendingPathComponent("attachments", isDirectory: true)
        let target = folder.appendingPathComponent(ref.storedName)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) {
                try manager.removeItem(at: target)
            }
            try manager.copyItem(at: AttachmentStore.shared.url(for: ref), to: target)
            return "attachments/" + ref.storedName
        } catch {
            return nil
        }
    }

    private func systemPrompt(sessionID: UUID) -> String {
        let base = basePrompt(sessionID: sessionID)
        let override = systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if override.isEmpty { return base }
        return override + "\n\n" + base
    }

    private func basePrompt(sessionID: UUID) -> String {
        let isChat = sessions.first(where: { $0.id == sessionID })?.mode != .work
        if isChat {
            return """
            你是运行在 iPad 上的 DeepSeek Harness 客户端里的助手。

            当前会话模式：「对话」模式。这一点以本段为准 —— 历史消息里如果提到别的模式，那是切换模式之前的旧说法，已作废。

            对话模式没有工具：你看不到这台设备上的文件，也没有 shell，不能执行任何命令。需要时直接说明你做不到，不要假装调用过工具。用户要你改文件或看文件时，提醒他把会话切到「工作」模式（顶部模式胶囊）。被问到「你现在是什么模式」时，回答「对话模式」。

            行为准则：
            - 回答用中文，直接给结论，不要客套。
            - 需要查资料就说明你知道什么、不确定什么。

            排版：回复按 Markdown 写（标题、列表、引用、代码块都用 Markdown）。数学公式用 LaTeX —— 行内写 $...$，独立成行的公式写 $$...$$；不要用反斜杠加方括号、或反斜杠加圆括号那种转义定界符。

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

        文件与权限：
        - 先动手试，不要预设「没权限」。工作目录（Documents/workspace）和 mount:<名字>/... 一定能读写。
        - 文件路径相对工作目录，也可以用 mount:<名字>/... 访问用户授权过的文件夹。
        \(mountLine)
        - Documents 之外的沙盒路径、系统目录、别的 App 的私有目录通常会被 iOS 拒绝。真被拒绝时工具会返回「错误：…」，这时再告诉用户这个位置改不了，并建议在设置里用「添加外部文件夹」授权一个可写目录。不要拿「可能没权限」当理由提前拒绝干活。
        - 这台设备上没有 shell、没有 git、没有编译器，也不能起子进程 —— 这不是权限问题，是根本没有这种能力：要算东西用 run_js，要取网页用 fetch_url。

        可用工具：list_dir / read_file / write_file / edit_file / make_dir / delete_path / move_path / copy_path / search_files / file_info / fetch_url / run_js / now / open_url / app_config。

        除了读写文件，你还能：
        - open_url：在设备上打开网页或别的 App（https://…、shortcuts://、safari://、maps:// 等），用户说「帮我打开 X」就直接调。
        - app_config：读取或修改这个 App 自己的设置 —— model（模型名）、effort（推理等级）、base_url（接口地址）、card_opacity（卡片不透明度）、max_rounds（轮数上限）、warn_before_run（开跑提醒）、system_prompt（系统提示词）。用户说「换个模型」「把界面调透一点」「以后回答简短点」这类要求，直接改设置，不要让用户自己去翻菜单。

        改文件先用 read_file 看原文，再用 edit_file 按原文替换；整篇重写才用 write_file。找不到东西就用 search_files 搜。

        行为准则：
        - 回答用中文，直接给结论和步骤，不要客套。
        - 工具返回以「错误：」开头表示失败，不要当作正常结果继续编造。
        - 长任务先给一句计划，再动手。

        排版：回复按 Markdown 写（标题、列表、引用、表格、代码块都用 Markdown，代码块要标语言）。数学公式用 LaTeX —— 行内写 $...$，独立成行的公式写 $$...$$；不要用反斜杠加方括号、或反斜杠加圆括号那种转义定界符。

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
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else { return }
        if let decoded = try? JSONDecoder().decode([ChatSession].self, from: data), !decoded.isEmpty {
            sessions = decoded
            currentSessionID = decoded[0].id
            return
        }
        // 整份解码失败时逐条抢救：坏一条不该连带丢掉其它会话。
        let salvaged = salvageSessions(from: data)
        if !salvaged.isEmpty {
            backupStoreFile()
            sessions = salvaged
            currentSessionID = salvaged[0].id
            save()
            return
        }
        backupStoreFile()
    }

    /// 把 JSON 数组逐元素解码，跳过错的那几条，剩下的照样能用。
    private func salvageSessions(from data: Data) -> [ChatSession] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoder = JSONDecoder()
        var result: [ChatSession] = []
        for element in raw {
            guard let piece = try? JSONSerialization.data(withJSONObject: element),
                  let session = try? decoder.decode(ChatSession.self, from: piece) else { continue }
            result.append(session)
        }
        return result
    }

    /// 解码失败的文件留一份，别让下一次 save 直接覆盖掉。
    private func backupStoreFile() {
        let backup = storeURL.deletingLastPathComponent().appendingPathComponent("sessions.bak.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: storeURL, to: backup)
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
