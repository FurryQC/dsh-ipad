import SwiftUI

// MARK: - 根视图

/// 两栏：左边会话，右边对话。壁纸铺在最底层，所有面板半透明浮在上面。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var wallpaper = WallpaperStore.shared

    var body: some View {
        WallpaperBackground {
            NavigationSplitView {
                SessionList()
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                ChatScreen()
            }
            .navigationSplitViewStyle(.balanced)
        }
        .onAppear { wallpaper.load() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: model.handleScenePhase(.active)
            case .inactive: model.handleScenePhase(.inactive)
            case .background: model.handleScenePhase(.background)
            @unknown default: break
            }
        }
        .alert("任务运行期间别切走", isPresented: Binding(
            get: { model.showSwitchWarning },
            set: { if !$0 { model.cancelSwitchWarning() } }
        )) {
            Button("开始任务") { model.confirmSwitchWarning() }
            Button("取消", role: .cancel) { model.cancelSwitchWarning() }
        } message: {
            Text("iPadOS 会在 App 进入后台几十秒后挂起它，正在跑的请求会被切断。任务做完再切。")
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 侧边栏

struct SessionList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(model.sessions) { session in
                    sessionRow(session)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                                .fill(session.id == model.currentSessionID ? Theme.accentSoft : Color.clear)
                                .padding(.vertical, 2)
                        )
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(session.id) }
                }
                .onDelete { indexSet in
                    let ids = indexSet.map { model.sessions[$0].id }
                    ids.forEach { model.deleteSession($0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color.clear)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("DSH")
                .font(Theme.title(22))
                .foregroundColor(Theme.textPrimary)
            Text("iPad")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.surfaceStrong)
                )
            Spacer()
            Button {
                model.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(model.isRunning ? Theme.textTertiary : Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.surface))
            }
            .disabled(model.isRunning)
        }
        .padding(.horizontal, Theme.pad)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(Theme.body(15))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Text(summary(session))
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    private func summary(_ session: ChatSession) -> String {
        let count = session.items.count
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        let time = formatter.localizedString(for: session.updatedAt, relativeTo: Date())
        return "\(count) 条 · \(time)"
    }
}

// MARK: - 对话

struct ChatScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showWallpaper = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.isRunning { runningBanner }
            if let text = model.errorText { errorBanner(text) }
            messageList
            composer
        }
        .background(Color.clear)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: $showPlugins) {
            NavigationView {
                PluginListView(host: PluginHost.shared)
                    .navigationTitle("插件")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showPlugins = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showWallpaper) {
            NavigationView {
                WallpaperPickerView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { showWallpaper = false }
                        }
                    }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            modelMenu
            effortMenu
            Spacer()
            iconButton("puzzlepiece.extension") { showPlugins = true }
            iconButton("photo") { showWallpaper = true }
            iconButton("gearshape") { showSettings = true }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 10)
        .background(Theme.bg.opacity(0.55))
    }

    private var modelMenu: some View {
        Menu {
            if model.availableModels.isEmpty {
                Button("刷新模型列表") { Task { await model.fetchModels() } }
            } else {
                ForEach(model.availableModels) { option in
                    Button {
                        model.model = option.id
                    } label: {
                        if option.id == model.model {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
                Divider()
                Button("刷新模型列表") { Task { await model.fetchModels() } }
            }
        } label: {
            chip(model.model, systemImage: "cpu")
        }
    }

    private var effortMenu: some View {
        Menu {
            ForEach(MessagesAPI.efforts, id: \.self) { effort in
                Button {
                    model.reasoningEffort = effort
                } label: {
                    if effort == model.reasoningEffort {
                        Label(effortLabel(effort), systemImage: "checkmark")
                    } else {
                        Text(effortLabel(effort))
                    }
                }
            }
        } label: {
            chip(effortLabel(model.reasoningEffort), systemImage: "brain")
        }
    }

    private func effortLabel(_ effort: String) -> String {
        switch effort {
        case "off": return "推理关"
        case "low": return "推理低"
        case "high": return "推理高"
        case "max": return "推理最高"
        default: return effort
        }
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surface.opacity(0.9)))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surface.opacity(0.9)))
        }
    }

    private var runningBanner: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.75)
            Text(model.statusLine.isEmpty ? "正在运行…" : model.statusLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.warning)
                .lineLimit(1)
            Spacer()
            Text("请留在本 App")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.warning.opacity(0.8))
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.12))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.errorText = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.pad)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.currentItems) { item in
                        MessageRow(item: item).id(item.id)
                    }
                    if model.isRunning && !model.reasoningPreview.isEmpty {
                        ReasoningBubble(text: model.reasoningPreview, streaming: true)
                    }
                    if model.isRunning && !model.streamPreview.isEmpty {
                        AssistantBubble(text: model.streamPreview, streaming: true)
                            .id("stream-preview")
                    }
                    if model.currentItems.isEmpty {
                        emptyHint
                    }
                }
                .padding(.horizontal, Theme.pad)
                .padding(.vertical, 16)
            }
            .onChange(of: model.currentItems.count) { _ in scrollToBottom(proxy) }
            .onChange(of: model.streamPreview) { _ in scrollToBottom(proxy) }
            .onChange(of: model.reasoningPreview) { _ in scrollToBottom(proxy) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("说点什么")
                .font(Theme.title(20))
                .foregroundColor(Theme.textPrimary)
            Text("工具和文件都在这台 iPad 上执行，模型走 API。文件在「文件」App 的 DSH/workspace 里，可以直接拖进来。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.currentItems.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.stroke)
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .frame(minHeight: 40, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 4)
                HStack(spacing: 8) {
                    if model.isRunning {
                        Label("运行中", systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.warning)
                    }
                    Spacer()
                    Button {
                        if model.isRunning {
                            model.stop()
                        } else {
                            let text = draft
                            draft = ""
                            model.send(text)
                        }
                    } label: {
                        Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(model.isRunning ? Theme.bg : Theme.textTertiary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(model.isRunning ? Theme.danger : Theme.accent))
                    }
                    .disabled(!model.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surface.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .padding(.horizontal, Theme.pad)
            .padding(.vertical, 10)
        }
        .background(Theme.bg.opacity(0.5))
    }

    @State private var draft = ""
}

// MARK: - 消息

struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .fill(Theme.accentSoft)
                    )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = item.reasoning, !reasoning.isEmpty {
                    ReasoningBubble(text: reasoning, streaming: false)
                }
                if !item.text.isEmpty {
                    AssistantBubble(text: item.text, streaming: false)
                } else if item.toolCalls.isEmpty && item.isError {
                    Text("（没有输出）")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                ForEach(item.toolCalls) { call in
                    ToolChip(call: call)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolCard(item: item)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let streaming: Bool

    var body: some View {
        HStack(spacing: 8) {
            if streaming {
                ProgressView().scaleEffect(0.65)
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dshCard(padding: 0)
    }
}

struct ReasoningBubble: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .semibold))
                    Text(streaming ? "思考中…" : "思考过程")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Theme.textTertiary)
            }
            if expanded {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.surface.opacity(0.55))
        )
    }
}

/// 助手要调用的工具先亮一张小条，执行结果在下一行 ToolCard 里。
struct ToolChip: View {
    let call: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10, weight: .semibold))
            Text(call.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accentSoft))
    }
}

struct ToolCard: View {
    let item: ChatItem
    @State private var expanded = false

    private var color: Color { item.isError ? Theme.danger : Theme.textSecondary }
    private var title: String { item.toolName ?? "工具结果" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.isError ? "exclamationmark.triangle" : "terminal")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(color)
                    Text(firstLine)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            if expanded {
                Divider().overlay(Theme.stroke)
                ScrollView(.vertical, showsIndicators: true) {
                    Text(item.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.surface.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(item.isError ? Theme.danger.opacity(0.4) : Theme.stroke, lineWidth: 1)
        )
    }

    private var firstLine: String {
        let line = item.text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "（空）" : line
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showKey = false
    @State private var keyError: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 8) {
                        if showKey {
                            TextField("sk-...", text: $model.apiKey)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("sk-...", text: $model.apiKey)
                                .font(.system(.body, design: .monospaced))
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    TextField("接口地址", text: $model.baseURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Text("模型")
                        Spacer()
                        Text(model.model).foregroundColor(Theme.textSecondary)
                    }
                } header: {
                    Text("DeepSeek")
                } footer: {
                    Text("key 存在这台设备的钥匙串里，不写进会话文件。默认地址是 https://api.deepseek.com/anthropic，和桌面版一致。")
                }

                Section {
                    Button {
                        Task { await model.fetchModels() }
                    } label: {
                        HStack {
                            Text("刷新模型列表")
                            Spacer()
                            if model.isFetchingModels { ProgressView().scaleEffect(0.8) }
                        }
                    }
                    ForEach(MessagesAPI.efforts, id: \.self) { effort in
                        Button {
                            model.reasoningEffort = effort
                        } label: {
                            HStack {
                                Text(effortTitle(effort))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                if effort == model.reasoningEffort {
                                    Image(systemName: "checkmark").foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("模型与推理")
                } footer: {
                    Text(effortFooter)
                }

                Section {
                    Stepper(value: $model.maxRounds, in: 4...80) {
                        HStack {
                            Text("最多工具轮数")
                            Spacer()
                            Text("\(model.maxRounds)").foregroundColor(Theme.textSecondary)
                        }
                    }
                    Toggle("开跑前提醒别切走", isOn: $model.warnBeforeRun)
                } header: {
                    Text("运行")
                }

                Section {
                    HStack {
                        Text("工作目录")
                        Spacer()
                        Text("DSH/workspace").foregroundColor(Theme.textSecondary)
                    }
                    Button("复制目录路径") {
                        UIPasteboard.general.string = Workspace.root.path
                    }
                } header: {
                    Text("文件")
                } footer: {
                    Text("在「文件」App 的「我的 iPad」里能看到 DSH 文件夹。")
                }

                Section {
                    Text("这是原生 iOS App：模型走 API，工具和文件都在这台设备上跑。iOS 不允许创建子进程，所以没有 shell —— 需要计算用 run_js，需要网页内容用 fetch_url。")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                } header: {
                    Text("能力边界")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if Keychain.saveAPIKey(model.apiKey) {
                            dismiss()
                        } else {
                            keyError = "钥匙串写入失败，key 没存上。重新签名后再试。"
                        }
                    }
                }
            }
            .alert("API key 没存上", isPresented: Binding(
                get: { keyError != nil },
                set: { if !$0 { keyError = nil } }
            )) {
                Button("知道了", role: .cancel) { keyError = nil }
            } message: {
                Text(keyError ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func effortTitle(_ effort: String) -> String {
        switch effort {
        case "off": return "关闭 · 简单任务最快"
        case "low": return "低 · 日常和省时间"
        case "high": return "高 · 默认的平衡档"
        case "max": return "最高 · 只在最难的活上用"
        default: return effort
        }
    }

    private var effortFooter: String {
        "推理等级对应 DeepSeek 的 thinking effort：关闭不发思考，最高会明显更慢也更贵。"
    }
}
