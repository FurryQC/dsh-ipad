import Combine
import UniformTypeIdentifiers
import UserNotifications
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
    /// 全局累计 token（跨所有会话，落 UserDefaults）。设置页顶部显示。
    @Published private(set) var totalTokens: Int = 0

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
    /// 正在等模型起标题的会话。防止同一轮触发两次请求。
    private var autoTitling: Set<UUID> = []
    /// send 之后、真正开跑之前（可能中间插了个「别切走」确认框），附件得先存着。
    private var queuedAttachments: [AttachmentRef] = []

    private enum Keys {
        static let baseURL = "dsh.baseURL"
        static let model = "dsh.model"
        static let effort = "dsh.effort"
        static let maxRounds = "dsh.maxRounds"
        static let warnBeforeRun = "dsh.warnBeforeRun"
        static let cardOpacity = "dsh.cardOpacity"
        static let totalTokens = "dsh.totalTokens"
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
        totalTokens = defaults.integer(forKey: Keys.totalTokens)
        systemPromptOverride = UserDefaults.standard.string(forKey: AppModel.systemPromptKey) ?? ""
        installWatchBridge()
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
    /// 返回 nil 表示成功；否则是给人看的失败原因，调用方要当场显示出来。
    @discardableResult
    func importAttachment(from url: URL) -> String? {
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
            return nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toast = "文件没加上：\(reason)"
            return "读不到 \(url.lastPathComponent)：\(reason)"
        }
    }

    /// 兼容旧调用点。
    func addAttachment(from url: URL) {
        _ = importAttachment(from: url)
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
        sortSessions()
        save()
    }

    /// 「自定义壁纸」：新开一个工作会话，让模型把单文件 HTML 写到工作目录的 wallpaper.html，
    /// 跑完自动装成壁纸。用户描述只要一句，剩下的排版约束由我们补全。
    func startCustomWallpaper(prompt: String) {
        guard !isRunning else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let session = ChatSession(title: "自定义壁纸", mode: .work)
        sessions.insert(session, at: 0)
        currentSessionID = session.id
        sortSessions()
        mutate(session.id) { $0.items.append(ChatItem(role: .user, text: trimmed)) }
        save()
        let instructions = """
        用户想要一张网页壁纸（HTML 背景）。他的描述是：

        \(trimmed)

        请用 write_file 在工作目录根下写一个单文件 HTML，路径固定为 wallpaper.html。硬性要求：
        - 单文件自包含：CSS/JS 全部内联，不引用任何外部网络资源（不要 CDN、不要外链图片/字体）。
        - 铺满整个屏幕：html、body 设 margin:0;padding:0;width:100%;height:100%;overflow:hidden；画面要适配任意宽高比，不能出现滚动条。
        - 按深色底设计，主体不要居中挤满（App 会在上面盖半透明面板，边缘留一点呼吸空间）。
        - 可以用 CSS 动画或 canvas，但不要请求摄像头/麦克风，不要出声。
        写完后用 file_info 确认 wallpaper.html 存在，再用一句话告诉用户效果。
        """
        startRun(prompt: instructions, appendUserMessage: false)
    }

    /// 自定义壁纸跑完后自动装上：只认标题为「自定义壁纸」的会话，且文件确实存在。
    private func applyGeneratedWallpaperIfNeeded(sessionID: UUID) {
        guard sessions.first(where: { $0.id == sessionID })?.title == "自定义壁纸" else { return }
        let url = Workspace.root.appendingPathComponent("wallpaper.html")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try WallpaperStore.shared.importHTML(from: url)
            toast = "壁纸已经换上了"
        } catch {
            toast = "壁纸没装上：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// 切换当前会话的模式。运行中不改，免得同一轮里规则前后不一致。
    func setMode(_ mode: SessionMode) {        guard !isRunning else { return }
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

    // MARK: - 会话管理（重命名 / 置顶 / 多选删除 / 自动标题）

    /// 重命名。空标题直接忽略，免得列表里出现一行空白。
    func renameSession(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.title = String(trimmed.prefix(40)) }
        save()
    }

    /// 置顶开关。置顶的排最上面，其余按最近更新时间。
    func togglePin(_ id: UUID) {
        mutate(id) { $0.pinned.toggle() }
        sortSessions()
        save()
    }

    /// 多选删除。全删空了就留一个新的工作会话，免得侧栏整块消失。
    func deleteSessions(_ ids: Set<UUID>) {
        guard !isRunning, !ids.isEmpty else { return }
        let remaining = sessions.filter { !ids.contains($0.id) }
        sessions = remaining.isEmpty ? [ChatSession(title: SessionMode.work.title, mode: .work)] : remaining
        if !sessions.contains(where: { $0.id == currentSessionID }) {
            currentSessionID = sessions[0].id
        }
        save()
    }

    /// 导入 DeepSeek App 导出的对话包。返回一句给用户看的结果。
    @discardableResult
    func importDeepSeekSessions(from url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try DeepSeekImport.load(from: url)
            guard !result.sessions.isEmpty else { return "导出包里没有可导入的对话。" }
            sessions.insert(contentsOf: result.sessions, at: 0)
            currentSessionID = result.sessions[0].id
            sortSessions()
            save()
            let skipped = result.skipped > 0 ? "，跳过 \(result.skipped) 个空会话" : ""
            return "已导入 \(result.sessions.count) 个对话\(skipped)。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "导入失败：\(reason)"
        }
    }

    /// 置顶在前，同组按更新时间倒序。
    private func sortSessions() {
        sessions.sort { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// 第一轮回答结束后把这段对话总结成 ≤20 字的标题。
    /// 模型请求失败就退回「首条消息前 20 字」—— 至少比「新对话」有信息。
    private func autoTitleIfNeeded(sessionID: UUID) {
        guard !autoTitling.contains(sessionID) else { return }
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let defaults = [SessionMode.chat.title, SessionMode.work.title]
        guard defaults.contains(session.title) else { return }
        guard let firstUser = session.items.first(where: { $0.role == .user })?.text else { return }
        let text = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        autoTitling.insert(sessionID)

        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let fallback = String(flat.prefix(20))
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = MessagesAPI.endpoint(base: baseURL) else {
            applyTitle(fallback, sessionID: sessionID)
            return
        }
        let options = MessagesAPI.RequestOptions(
            model: "deepseek-flash",
            system: "你负责给对话起标题。只输出一个不超过 20 个字的中文标题，不加引号、不加标点、不解释。",
            effort: "off",
            maxTokens: 64,
            messages: [["role": "user", "content": "给这段用户需求起个标题：" + String(flat.prefix(400))]],
            tools: []
        )
        guard let body = MessagesAPI.body(options) else {
            applyTitle(fallback, sessionID: sessionID)
            return
        }
        let request = MessagesAPI.request(url: url, apiKey: key, body: body)
        Task { @MainActor [weak self] in
            var title = ""
            if let turn = try? await MessagesAPI.stream(request: request, onText: { _ in }, onReasoning: { _ in }) {
                title = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            title = title.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "「", with: "")
                .replacingOccurrences(of: "」", with: "")
                .replacingOccurrences(of: "\n", with: " ")
            if title.isEmpty { title = fallback }
            self?.applyTitle(String(title.prefix(20)), sessionID: sessionID)
        }
    }

    /// 只在标题还是默认值时写，避免覆盖用户手动改过的名字。
    private func applyTitle(_ title: String, sessionID: UUID) {
        autoTitling.remove(sessionID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let defaults = [SessionMode.chat.title, SessionMode.work.title]
        mutate(sessionID) { session in
            if defaults.contains(session.title) {
                session.title = trimmed
            }
        }
        sortSessions()
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
            recordTokens(input: turn.inputTokens, output: turn.outputTokens, sessionID: sessionID)

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
        autoTitleIfNeeded(sessionID: sessionID)
        applyGeneratedWallpaperIfNeeded(sessionID: sessionID)
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

            对话模式没有文件工具：你看不到这台设备上的文件，也没有 shell，不能执行任何命令。不要假装调用过工具；但也不要预先说做不到 —— open_url、open_settings、app_config 这几个工具在对话模式下也能用。用户要你改文件或看文件时，提醒他把会话切到「工作」模式（顶部模式胶囊）。被问到「你现在是什么模式」时，回答「对话模式」。

            硬规则（优先于下面所有内容）：
            - 不要说「我做不到」「我没有权限」「我无法访问」「作为 AI 我不能」这类话。只有某个工具真的返回了「错误：…」之后，才说这件事办不成，并给出下一步。
            - 用户要你做事时，先想「哪个工具能做」；能就调工具，不要用解释代替动手。
            - 你现在处于对话模式（没有文件工具）。用户要你动文件、打开 App、改设置时，第一句就给指引：点顶部的模式胶囊把会话切到「工作」模式，然后就能动手。别先说做不到。

            动手优先的流程（每个请求都走一遍）：
            1. 先调一个工具去试 —— 哪怕明知大概率不行（比如用户让你删 App：先试 app_config 看有没有这个能力，或直接 open_settings 把用户带过去）。一句话都没动手就回「做不到」是违规的。
            2. 工具返回「错误：…」或明确表示没有这个能力之后，才承认这一步做不了；同时立刻做两件事：把用户带到能做的地方（open_settings / open_url），并给出 3 步以内的具体操作路径。
            3. 最后一句问一句「要不要我继续做剩下的部分」，不要以「抱歉」收尾。
            示例：用户说「把这个 App 删了」→ 先调 open_settings（section=STORAGE），然后写：「应用卸载只能你手动做：设置 → 通用 → iPad 储存空间 → 找到 DSH → 删除 App。我已经帮你打开设置了。」


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

        硬规则（优先于下面所有内容）：
        - 不要说「我做不到」「我没有权限」「我无法访问」「作为 AI 我不能」这类话。只有某个工具真的返回了「错误：…」之后，才说这件事办不成，并给出下一步。
        - 用户要你做事时，先想「哪个工具能做」；能就调工具，不要用解释代替动手。做完再汇报，别先声明限制。

        动手优先的流程（每个请求都走一遍）：
        1. 先调一个工具去试 —— 哪怕明知大概率不行（比如用户让你卸载 App：先试 app_config 看有没有这个能力，或直接 open_settings 把用户带过去）。一句话都没动手就回「做不到」是违规的。
        2. 工具返回「错误：…」或明确表示没有这个能力之后，才承认这一步做不了；同时立刻做两件事：把用户带到能做的地方（open_settings / open_url），并给出 3 步以内的具体操作路径。
        3. 最后一句问「要不要我继续做剩下的部分」，不要以「抱歉」收尾。
        示例：用户说「把这个 App 删了」→ 先调 open_settings（section=STORAGE），然后写：「应用卸载只能你手动做：设置 → 通用 → iPad 储存空间 → 找到 DSH → 删除 App。我已经帮你打开设置了。」

        文件与权限：
        - 先动手试，不要预设「没权限」。工作目录（Documents/workspace）和 mount:<名字>/... 一定能读写。
        - 文件路径相对工作目录，也可以用 mount:<名字>/... 访问用户授权过的文件夹。
        \(mountLine)
        - Documents 之外的沙盒路径、系统目录、别的 App 的私有目录通常会被 iOS 拒绝。真被拒绝时工具会返回「错误：…」，这时再告诉用户这个位置改不了，并建议在设置里用「添加外部文件夹」授权一个可写目录。不要拿「可能没权限」当理由提前拒绝干活。
        - 这台设备上没有 shell、没有 git、没有编译器，也不能起子进程 —— 这不是权限问题，是根本没有这种能力：要算东西用 run_js，要取网页用 fetch_url。

        可用工具：list_dir / read_file / write_file / edit_file / make_dir / delete_path / move_path / copy_path / search_files / file_info / fetch_url / run_js / now / open_url / app_config / open_settings。

        除了读写文件，你还能：
        - open_url：在设备上打开网页或别的 App（https://…、shortcuts://、safari://、maps:// 等），用户说「帮我打开 X」就直接调。
        - app_config：读取或修改这个 App 自己的设置 —— model（模型名）、effort（推理等级）、base_url（接口地址）、card_opacity（卡片不透明度）、max_rounds（轮数上限）、warn_before_run（开跑提醒）、system_prompt（系统提示词）。用户说「换个模型」「把界面调透一点」「以后回答简短点」这类要求，直接改设置，不要让用户自己去翻菜单。
        - open_settings：打开系统设置（section 可选 General / STORAGE / PRIVACY / NOTIFICATIONS）。卸载 App、改通知、改隐私授权这类 App 内做不到的事，先调它把用户带过去，再给具体路径。

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

    /// 把一轮请求的 usage 记到会话和全局。服务端偶尔回 0（比如流被中断），
    /// 这种情况跳过，免得把已累计的数字清零。
    // MARK: - 屏幕识别（由 screen_watch 工具驱动）

    /// 识别是否在跑。
    @Published var watchActive = false
    /// 开始识别时需要弹出「解释 + 系统广播按钮」那一页。
    @Published var showWatchStart = false

    /// 已经收到的帧数、最近一帧到达时间（给设置页和工具状态看）。
    @Published private(set) var watchFrames = 0
    @Published private(set) var watchLastFrameAt: Date?

    private var watchPoll: Task<Void, Never>?
    /// 上一次已经发出去识别的那帧时间戳，用来去重。
    private var lastFrameStamp: Double = 0
    /// 上一次识别还没回来就不再发新帧，避免堆积。
    private var watchInFlight = false

    /// 把工具调用接到界面动作上。初始化时调用一次。
    @MainActor
    private func installWatchBridge() {
        Tools.watchStart = { [weak self] prompt, interval in
            guard let self else { return "错误：App 已经关闭。" }
            return self.beginScreenWatch(prompt: prompt, interval: interval)
        }
        Tools.watchStop = { [weak self] in
            guard let self else { return "错误：App 已经关闭。" }
            return self.endScreenWatch()
        }
        Tools.watchStatus = { [weak self] in
            guard let self else { return "错误：App 已经关闭。" }
            return self.screenWatchStatus()
        }
    }

    /// 把配置写进 App Group，并弹出「开始直播」那一页（iOS 只允许用户亲手点开始）。
    func beginScreenWatch(prompt: String, interval: Double) -> String {
        let key = Keychain.loadAPIKey()
        guard !key.isEmpty else {
            return "错误：还没设置 DeepSeek API key，识别跑不起来。先让用户去设置里填 key。"
        }
        var config = WatchShared.load()
        config.apiKey = key
        config.baseURL = baseURL
        config.model = "deepseek-flash"
        config.effort = "off"
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.prompt = prompt
        }
        config.intervalSeconds = min(5, max(1, interval))
        config.enabled = true
        config.notify = true
        WatchShared.save(config)
        WatchShared.clearFrames()
        // 扩展读不到 App Group 时用这条 loopback 通道取配置（重签后 entitlement 常丢）。
        WatchConfigServer.shared.serve(config)

        watchFrames = 0
        watchLastFrameAt = nil
        lastFrameStamp = 0
        watchActive = true
        showWatchStart = true
        requestWatchNotificationPermission()
        startWatchPolling()
        return "已准备好屏幕识别（flash 模型 + 推理关，每 \(Int(config.intervalSeconds)) 秒取一帧）。现在界面上已经弹出「开始直播」那一页，需要用户亲手点一下里面的圆钮 —— 这是 iOS 的硬限制。点完之后请再调一次 action=status 确认收到画面；在拿到帧之前，不要对用户说「没开启」或「失败」，那只是用户还没点按钮。"
    }

    func endScreenWatch() -> String {
        var config = WatchShared.load()
        config.enabled = false
        WatchShared.save(config)
        watchPoll?.cancel()
        watchPoll = nil
        watchActive = false
        watchInFlight = false
        WatchShared.clearFrames()
        WatchConfigServer.shared.stop()
        appendItem(ChatItem(role: .assistant, text: "屏幕识别已结束。", tag: "watch"), to: currentSessionID)
        return "屏幕识别已停止，产生的记录在对话里折叠成「屏幕识别信息」一组。"
    }

    private func screenWatchStatus() -> String {
        let config = WatchShared.load()
        if !watchActive {
            return "屏幕识别没在跑。需要时调 action=start。"
        }
        let group = WatchShared.groupAvailable ? "可用" : "不可用"
        if let last = watchLastFrameAt {
            let ago = Int(Date().timeIntervalSince(last))
            return "屏幕识别在跑：已收到 \(watchFrames) 帧，最近一帧 \(ago) 秒前，每 \(Int(config.intervalSeconds)) 秒取一帧。共享容器：\(group)。要停就调 action=stop。"
        }
        return "已准备好，但还没收到任何画面（0 帧）。这通常表示用户还没点系统里那个「开始直播」圆钮 —— 不要判定失败，先提醒用户点一下，再调一次 status。共享容器：\(group)。"
    }

    private func requestWatchNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.toast = granted ? "通知权限已允许：识别结果会弹通知" : "通知权限被拒绝：结果只会出现在对话里"
            }
        }
    }

    private func startWatchPolling() {
        watchPoll?.cancel()
        watchPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                await MainActor.run { self.pollWatchFrames() }
            }
        }
    }

    /// 主 App 从共享容器读扩展写下的帧，自己发请求、自己出结果 —— 扩展只负责截图。
    private func pollWatchFrames() {
        guard watchActive, !watchInFlight, let frame = WatchShared.takeFrame(after: lastFrameStamp) else { return }
        lastFrameStamp = frame.stamp
        watchFrames += 1
        watchLastFrameAt = Date(timeIntervalSince1970: frame.stamp)
        watchInFlight = true

        var config = WatchShared.load()
        config.apiKey = Keychain.loadAPIKey()
        config.baseURL = baseURL
        config.model = "deepseek-flash"
        config.effort = "off"
        let jpegBase64 = frame.jpeg.base64EncodedString()
        let sessionID = currentSessionID

        Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await WatchVision.ask(jpegBase64: jpegBase64, config: config))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                guard let self else { return }
                self.watchInFlight = false
                switch outcome {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    WatchShared.recordResult(trimmed)
                    self.appendItem(ChatItem(role: .assistant, text: trimmed, tag: "watch"), to: sessionID)
                    self.trimWatchItems()
                    self.postWatchNotification(trimmed)
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.appendItem(ChatItem(role: .assistant, text: "屏幕识别失败：" + message, tag: "watch"), to: sessionID)
                    self.trimWatchItems()
                }
            }
        }
    }

    private func postWatchNotification(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "DSH 屏幕识别"
        content.body = String(text.prefix(300))
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// 识别会一直产出，超过 80 条就把最老的挤掉，避免会话文件无限长大。
    private func trimWatchItems() {
        let sessionID = currentSessionID
        let watchIDs = sessions.first(where: { $0.id == sessionID })?.items.filter { $0.tag == "watch" }.map { $0.id } ?? []
        guard watchIDs.count > 80 else { return }
        let drop = Set(watchIDs.prefix(watchIDs.count - 80))
        mutate(sessionID) { $0.items.removeAll { drop.contains($0.id) } }
    }

    private func recordTokens(input: Int, output: Int, sessionID: UUID) {
        guard input > 0 || output > 0 else { return }
        mutate(sessionID) {
            $0.tokensIn += input
            $0.tokensOut += output
        }
        totalTokens += input + output
        UserDefaults.standard.set(totalTokens, forKey: Keys.totalTokens)
    }

    private func mutate(_ sessionID: UUID, _ body: (inout ChatSession) -> Void) {        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
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
