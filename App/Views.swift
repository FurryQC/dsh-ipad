import SwiftUI
import UniformTypeIdentifiers

// MARK: - 悬浮面板

/// 所有面板都用这一套：毛玻璃底 + 细描边 + 投影，四周留白，不贴着屏幕边。
private struct FloatingPanel: ViewModifier {
    var radius: CGFloat = 26

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.black.opacity(0.38), radius: 22, x: 0, y: 10)
    }
}

private extension View {
    func floatingPanel(radius: CGFloat = 26) -> some View {
        modifier(FloatingPanel(radius: radius))
    }
}

// MARK: - 根视图

/// 壁纸铺在最底层；左侧会话栏、右侧对话区都是悬浮卡片，四周离屏幕边缘有距离。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var wallpaper = WallpaperStore.shared
    @State private var showSidebar = true

    var body: some View {
        WallpaperBackground {
            GeometryReader { geo in
                HStack(spacing: 12) {
                    if showSidebar {
                        SidebarCard(showSidebar: $showSidebar)
                            .frame(width: min(300, max(248, geo.size.width * 0.26)))
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ChatCard(showSidebar: $showSidebar)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
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

// MARK: - 侧边栏卡片

struct SidebarCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        row(session)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .floatingPanel()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DSH")
                .font(Theme.title(21))
                .foregroundColor(Theme.textPrimary)
            Text("iPad")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 26, height: 26)
            }
            Menu {
                Button {
                    model.newSession(mode: .chat)
                } label: {
                    Label("新建对话 · 不带工具", systemImage: "bubble.left.and.bubble.right")
                }
                Button {
                    model.newSession(mode: .work)
                } label: {
                    Label("新建工作 · 可改文件", systemImage: "hammer")
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(model.isRunning ? Theme.textTertiary : Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }
            .disabled(model.isRunning)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func row(_ session: ChatSession) -> some View {
        let selected = session.id == model.currentSessionID
        return Button {
            model.select(session.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: session.mode.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(selected ? Theme.accent : Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(session))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.deleteSession(session.id)
            } label: {
                Label("删除对话", systemImage: "trash")
            }
            .disabled(model.isRunning || model.sessions.count <= 1)
        }
    }

    private func subtitle(_ session: ChatSession) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        let time = formatter.localizedString(for: session.updatedAt, relativeTo: Date())
        return "\(session.mode.title) · \(session.items.count) 条 · \(time)"
    }
}

// MARK: - 对话卡片

struct ChatCard: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showSidebar: Bool

    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showWallpaper = false
    @State private var draft = ""

    private var mode: SessionMode { model.currentSession?.mode ?? .chat }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.isRunning && mode == .work { runningBanner }
            if mode == .chat && !model.isRunning { chatHint }
            if let text = model.errorText { errorBanner(text) }
            messageList
            composer
        }
        .floatingPanel()
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

    /// 对话模式不加载工具，这里给一条可点的提示，避免用户以为工具坏了。
    private var chatHint: some View {
        Button {
            model.setMode(.work)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hammer")
                    .font(.system(size: 12, weight: .semibold))
                Text("对话模式不带工具，点这里切到工作模式")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundColor(Theme.warning)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.warning.opacity(0.10))
    }

    // MARK: 顶栏
    private var topBar: some View {
        HStack(spacing: 8) {
            if !showSidebar {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
            }
            modeMenu
            modelMenu
            effortMenu
            Spacer(minLength: 0)
            iconButton("puzzlepiece.extension") { showPlugins = true }
            iconButton("photo") { showWallpaper = true }
            iconButton("gearshape") { showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var modeMenu: some View {
        Menu {
            ForEach([SessionMode.chat, SessionMode.work], id: \.self) { option in
                Button {
                    model.setMode(option)
                } label: {
                    Label("\(option.title) · \(option.blurb)", systemImage: option.systemImage)
                }
            }
        } label: {
            chip(mode.title, systemImage: mode.systemImage, highlighted: true)
        }
        .disabled(model.isRunning)
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
            chip(model.model, systemImage: "cpu", highlighted: false)
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
            chip(effortLabel(model.reasoningEffort), systemImage: "brain", highlighted: false)
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

    private func chip(_ text: String, systemImage: String, highlighted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(highlighted ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(highlighted ? Theme.accentSoft : Color.white.opacity(0.08))
        )
    }

    private func iconButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
    }

    private var runningBanner: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.7)
            Text(model.statusLine.isEmpty ? "正在运行…" : model.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.warning)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("请留在本 App")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.warning.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.warning.opacity(0.12))
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(Theme.danger)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.errorText = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.danger.opacity(0.12))
    }

    // MARK: 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.currentItems.isEmpty {
                        emptyHint
                    }
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
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: model.currentItems.count) { _ in scrollToBottom(proxy) }
            .onChange(of: model.streamPreview) { _ in scrollToBottom(proxy) }
            .onChange(of: model.reasoningPreview) { _ in scrollToBottom(proxy) }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text(mode == .chat ? "先聊两句" : "说一句要做什么")
                    .font(Theme.title(19))
                    .foregroundColor(Theme.textPrimary)
            }
            Text(mode == .chat
                 ? "对话模式：不带工具、不碰文件，随便聊。需要动文件时切到「工作」。"
                 : "工作模式：可以读写工作目录里的文件。长任务跑起来请留在本 App，切到后台会被挂断。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 30)
        .frame(maxWidth: 460, alignment: .leading)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = model.currentItems.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: 输入区（卡片内再浮一层）

    private var composer: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(mode == .chat ? "说点什么…" : "要它做什么…")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .frame(minHeight: 38, maxHeight: 110)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            }
            HStack(spacing: 8) {
                if model.isRunning {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .semibold))
                        Text("运行中").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.warning)
                }
                Spacer(minLength: 0)
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
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(model.isRunning ? Theme.bg : Theme.textTertiary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(model.isRunning ? Theme.danger : Theme.accent))
                }
                .disabled(!model.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }
}

// MARK: - 消息组件

struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(item.text)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
        HStack(alignment: .top, spacing: 8) {
            if streaming {
                ProgressView().scaleEffect(0.6).padding(.top, 3)
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
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
                    Image(systemName: "brain").font(.system(size: 10, weight: .semibold))
                    Text(streaming ? "思考中…" : "思考过程")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

/// 助手要调用的工具先亮一张小条，执行结果在下一行 ToolCard 里。
struct ToolChip: View {
    let call: ToolCall

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
            Text(call.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                    Text(firstLine)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            if expanded {
                Divider().overlay(Color.white.opacity(0.08))
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(item.isError ? Theme.danger.opacity(0.35) : Color.white.opacity(0.07),
                              lineWidth: 1)
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
    @State private var mounts: [MountedFolder] = []
    @State private var showFolderPicker = false
    @State private var mountError: String?

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
                    Text("推理等级对应 DeepSeek 的 thinking effort：关闭不发思考，最高会明显更慢也更贵。")
                }

                Section {
                    Stepper(value: $model.maxRounds, in: 4...80) {
                        HStack {
                            Text("最多工具轮数")
                            Spacer()
                            Text("\(model.maxRounds)").foregroundColor(Theme.textSecondary)
                        }
                    }
                    Toggle("工作模式开跑前提醒别切走", isOn: $model.warnBeforeRun)
                } header: {
                    Text("运行")
                } footer: {
                    Text("对话模式不带工具，不会弹这个提醒。")
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
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("添加外部文件夹", systemImage: "folder.badge.plus")
                    }
                    if mounts.isEmpty {
                        Text("还没有授权外部文件夹。加一个之后，模型就能用 mount:<名字>/... 读写它。")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textTertiary)
                    } else {
                        ForEach(mounts) { mount in
                            HStack {
                                Image(systemName: "externaldrive")
                                    .foregroundColor(Theme.accent)
                                Text("mount:\(mount.name)")
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button {
                                    MountStore.shared.remove(id: mount.id)
                                    mounts = MountStore.shared.mounts
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(Theme.danger)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("文件")
                } footer: {
                    Text("在「文件」App 的「我的 iPad」里能看到 DSH 文件夹。外部文件夹在这里手动授权：选 iCloud 云盘、我的 iPad 或其它 App 暴露的目录都行，授权会一直有效，直到你删掉它。")
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
            .onAppear { mounts = MountStore.shared.mounts }
            .fileImporter(isPresented: $showFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        _ = try MountStore.shared.add(url: url)
                        mounts = MountStore.shared.mounts
                    } catch {
                        mountError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    }
                case .failure(let error):
                    mountError = error.localizedDescription
                }
            }
            .alert("文件夹没授权上", isPresented: Binding(
                get: { mountError != nil },
                set: { if !$0 { mountError = nil } }
            )) {
                Button("知道了", role: .cancel) { mountError = nil }
            } message: {
                Text(mountError ?? "")
            }
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
}
