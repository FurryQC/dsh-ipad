import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

// MARK: - 悬浮面板

/// 所有面板都用这一套：毛玻璃底 + 细描边 + 投影，四周留白，不贴着屏幕边。
/// 底衬的不透明度用 `@AppStorage` 读同一个键，跟设置页滑杆实时联动（壁纸想露多少由用户定）。
private struct FloatingPanel: ViewModifier {
    var radius: CGFloat = 26
    @AppStorage("dsh.cardOpacity") private var cardOpacity: Double = 0.72

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(cardOpacity)
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
    @State private var showSplash = true

    var body: some View {
        ZStack {
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
            // 所有系统选择器都在这一层弹：sheet 里再弹 sheet 会被 iOS 静默吞掉。
            .sheet(item: $model.pickerRequest) { request in
                DocumentPicker(mode: request == .folders ? .folders : .files) { urls in
                    model.pickerRequest = nil
                    model.handlePicked(urls, folders: request == .folders)
                }
                .ignoresSafeArea()
            }

            // 启动动画盖在最上层，自己跑完 1.66 秒后回调。下面这层透明蒙板拦住这期间的触摸。
            if showSplash {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { }
                    LaunchSplashOverlay(onFinish: { showSplash = false })
                }
                .zIndex(10)
            }
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
    @State private var draft = ""
    @State private var showAttachPanel = false
    /// 用户自己往上翻时停掉自动跟随；新消息、重新发送、点「回到底部」再打开。
    @State private var autoScroll = true

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
        .sheet(isPresented: $showAttachPanel) {
            AttachmentPanel()
                .environmentObject(model)
        }
        // 长按用户消息点「修改」：把原文塞回输入框。
        .onChange(of: model.draftInjection) { value in
            guard let value else { return }
            draft = value
            model.draftInjection = nil
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    .padding(.bottom, 92)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.toast) { value in
            guard value != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if model.toast == value { model.toast = nil }
            }
        }
    }

    /// 已选附件：横排缩略图，右上角红叉单独移除。
    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pendingAttachments) { ref in
                    AttachmentThumb(ref: ref) {
                        AttachmentStore.shared.delete(ref)
                        model.pendingAttachments.removeAll { $0.id == ref.id }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(height: 66)
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

    /// 把一轮任务的过程折成一行：带 tool_calls 的 assistant 消息 + 紧跟的 tool 结果合成一组。
    private var groupedRows: [MessageRowGroup] {
        var rows: [MessageRowGroup] = []
        var bucket: [ChatItem] = []
        var bucketID: UUID?

        func flush() {
            if let id = bucketID, !bucket.isEmpty {
                rows.append(.process(id, bucket))
            }
            bucket = []
            bucketID = nil
        }

        for item in model.currentItems {
            let isProcess = item.role == .tool || !item.toolCalls.isEmpty
            if isProcess {
                if bucketID == nil { bucketID = UUID() }
                bucket.append(item)
            } else {
                flush()
                rows.append(.single(item))
            }
        }
        flush()
        return rows
    }

    private var lastProcessID: UUID? {
        for row in groupedRows.reversed() {
            if case .process(let id, _) = row { return id }
        }
        return nil
    }

    private func seconds(for row: MessageRowGroup) -> Double? {
        guard case .process(let id, _) = row, id == lastProcessID else { return nil }
        return model.currentSession?.lastRunSeconds
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.currentItems.isEmpty {
                        emptyHint
                    }
                    ForEach(groupedRows) { row in
                        switch row {
                        case .single(let item):
                            MessageRow(item: item).id(item.id)
                        case .process(let id, let items):
                            ProcessGroup(items: items,
                                         seconds: seconds(for: row),
                                         isRunning: model.isRunning && id == lastProcessID)
                                .id(id)
                        }
                    }
                    if model.isRunning && !model.reasoningPreview.isEmpty {
                        ReasoningBubble(text: model.reasoningPreview, streaming: true)
                            .id("reasoning-preview")
                    }
                    if model.isRunning && !model.streamPreview.isEmpty {
                        AssistantBubble(text: model.streamPreview, streaming: true)
                            .id("stream-preview")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            // 手指一拖就停掉自动跟随：否则流式输出每来一段都会把正在看的位置往下拽。
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    if autoScroll { autoScroll = false }
                }
            )
            .onChange(of: model.currentItems.count) { _ in
                autoScroll = true
                scrollToBottom(proxy)
            }
            .onChange(of: model.streamPreview) { _ in
                if autoScroll { scrollToBottom(proxy) }
            }
            .onChange(of: model.reasoningPreview) { _ in
                if autoScroll { scrollToBottom(proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScroll {
                    Button {
                        autoScroll = true
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(.ultraThinMaterial))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                }
            }
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
        VStack(spacing: 6) {
            if !model.pendingAttachments.isEmpty {
                attachmentTray
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(mode == .chat ? "说点什么…" : "要它做什么…")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.vertical, 1)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.vertical, 1)
            }
            HStack(spacing: 8) {
                Button {
                    showAttachPanel = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .disabled(model.isRunning)
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
                        autoScroll = true
                        model.send(text)
                    }
                } label: {
                    Image(systemName: model.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(model.isRunning ? Theme.bg : Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(model.isRunning ? Theme.danger : Theme.accent))
                }
                .disabled(!model.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }
}

// MARK: - 消息组件

struct MessageRow: View {
    let item: ChatItem
    @EnvironmentObject private var model: AppModel
    @State private var shareItems: [Any]?

    var body: some View {
        switch item.role {
        case .user:
            userRow
        case .assistant:
            assistantRow
        case .tool:
            ToolCard(item: item)
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if !item.attachments.isEmpty {
                    AttachmentStrip(refs: item.attachments)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.accentSoft)
            )
            .contextMenu {
                Button {
                    if let text = model.takeBackPrompt(item.id) {
                        model.draftInjection = text
                    }
                } label: {
                    Label("修改", systemImage: "pencil")
                }
                Button {
                    MessageActions.copyToPasteboard(item.text)
                    model.toast = "已复制"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var assistantRow: some View {
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
        .contextMenu {
            Button {
                MessageActions.copyToPasteboard(item.text)
                model.toast = "已复制"
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            Button {
                model.regenerateLastReply()
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
            Button {
                model.toast = "已记录「喜欢」"
            } label: {
                Label("喜欢", systemImage: "hand.thumbsup")
            }
            Button {
                model.toast = "已记录「不喜欢」"
            } label: {
                Label("不喜欢", systemImage: "hand.thumbsdown")
            }
            Button {
                SpeechPlayer.shared.toggle(id: item.id, text: item.text)
            } label: {
                Label(SpeechPlayer.shared.speakingItemID == item.id ? "停止朗读" : "朗读", systemImage: "speaker.wave.2")
            }
            Button {
                shareItems = [item.text]
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        .sheet(isPresented: Binding(get: { shareItems != nil }, set: { if !$0 { shareItems = nil } })) {
            ShareSheet(items: shareItems ?? [])
        }
    }
}

/// 一条用户消息里的图片/文件小缩略图。手机上不放原尺寸，避免一张图占满一屏。
struct AttachmentStrip: View {
    let refs: [AttachmentRef]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(refs) { ref in
                if ref.kind == .image, let image = AttachmentStore.shared.image(for: ref) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill").font(.system(size: 10))
                        Text(ref.fileName).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                }
            }
        }
    }
}

/// 一轮任务里的「过程」（思考 + 工具调用）折成一行，默认收起；正在跑的这一轮默认展开。
struct ProcessGroup: View {
    let items: [ChatItem]
    let seconds: Double?
    let isRunning: Bool
    @State private var expanded: Bool

    init(items: [ChatItem], seconds: Double?, isRunning: Bool) {
        self.items = items
        self.seconds = seconds
        self.isRunning = isRunning
        _expanded = State(initialValue: isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "ellipsis" : "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(headerText)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        MessageRow(item: item)
                    }
                }
                .padding(.leading, 4)
                .padding(.vertical, 2)
            }
        }
    }

    private var headerText: String {
        if isRunning { return "正在处理…" }
        guard let seconds else { return "已完成" }
        let total = Int(seconds.rounded())
        if total < 60 { return "已完成，用时 \(max(total, 1)) 秒" }
        return "已完成，用时 \(total / 60) 分 \(total % 60) 秒"
    }
}

/// 消息列表的一行：要么是一条普通消息，要么是一折起来的「过程」。
enum MessageRowGroup: Identifiable {
    case single(ChatItem)
    case process(UUID, [ChatItem])

    var id: UUID {
        switch self {
        case .single(let item):
            return item.id
        case .process(let id, _):
            return id
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
            MarkdownView(text)
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

// MARK: - 附件

/// 输入框上方的一枚已选附件：图片显示缩略图，其它文件显示名字，右上角红叉可撤销。
struct AttachmentThumb: View {
    let ref: AttachmentRef
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if ref.kind == .image, let image = AttachmentStore.shared.image(for: ref) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "doc.fill").font(.system(size: 16))
                    Text(ref.fileName).font(.system(size: 9)).lineLimit(1)
                }
                .foregroundColor(Theme.textSecondary)
                .frame(width: 60, height: 60)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.danger)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .offset(x: 5, y: -5)
        }
        .frame(width: 64, height: 64)
    }
}

/// 「+」打出来的面板：相册 / 拍照 / 文件。图片直接进 Messages 的 image 块，文件复制进工作目录。
/// 系统文件 App 的选择器。文件拿回 security-scoped URL，调用方负责 start/stopAccessing。
struct DocumentPicker: UIViewControllerRepresentable {
    enum Mode {
        /// 多选任意文件
        case files
        /// 单选一个文件夹（外部目录授权用）
        case folders
    }

    let mode: Mode
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = mode == .folders ? [.folder] : [.item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = mode == .files
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}

struct AttachmentPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 38, height: 4)
                .padding(.top, 10)
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images, photoLibrary: .shared()) {
                    panelButton("相册", systemImage: "photo.on.rectangle")
                }
                Button {
                    showCamera = true
                } label: {
                    panelButton("拍照", systemImage: "camera")
                }
                Button {
                    // 面板自己就是一张 sheet，再从它上面弹系统选择器是允许的（iPadOS 会叠加显示）。
                    showFiles = true
                } label: {
                    panelButton("文件", systemImage: "paperclip")
                }
            }
            .padding(.horizontal, 18)
            // 兜底入口：文件选择器万一用不了，也能从 App 自己的工作目录里挑文件。
            workspacePicker
            Text("图片会先缩到 2048 长边再传（flash 模型能直接看图）；文件会复制进工作目录，agent 能用 read_file 读。也可以把文件拖进「文件」App 的 DSH/Documents 里，这里会列出来。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                await ingestPhotos(items)
                pickerItems = []
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                showCamera = false
                if let image, let data = image.jpegData(compressionQuality: 0.9) {
                    ingest(data: data, fileName: "camera.jpg", mimeType: "image/jpeg", kind: .image)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showFiles) {
            DocumentPicker(mode: .files) { urls in
                showFiles = false
                guard !urls.isEmpty else { return }
                // 统一交给 AppModel：它负责安全作用域访问、iCloud 下载兜底和 toast 反馈。
                model.handlePicked(urls, folders: false)
                dismiss()
            }
            .ignoresSafeArea()
        }
        .alert("附件没加上", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    /// 工作目录里的文件（含用户从「文件」App 拖进 DSH/Documents 的），点一下直接当附件。
    @ViewBuilder private var workspacePicker: some View {
        let files = workspaceFiles()
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("工作目录里的文件")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files, id: \.absoluteString) { url in
                            Button {
                                model.addAttachment(from: url)
                                dismiss()
                            } label: {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.10)))
                                    .foregroundColor(Theme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
    }

    private func workspaceFiles() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        func collect(_ dir: URL) {
            guard let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            result.append(contentsOf: items.filter { !$0.hasDirectoryPath })
        }
        collect(Workspace.root)
        collect(Workspace.root.deletingLastPathComponent())
        return Array(result.prefix(20))
    }

    private func panelButton(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .medium))
            Text(title).font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(Theme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.09)))
    }

    private func ingestPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                ingest(data: data, fileName: "photo.jpg", mimeType: "image/jpeg", kind: .image)
            } catch {
                errorText = "图片读取失败：\(error.localizedDescription)"
            }
        }
        if !model.pendingAttachments.isEmpty { dismiss() }
    }

    private func ingestFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // iCloud 里的文件可能还没落到本地，先要一份数据再读。
            let data: Data
            if let local = try? Data(contentsOf: url) {
                data = local
            } else {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                data = try Data(contentsOf: url)
            }
            let type = UTType(filenameExtension: url.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let kind: AttachmentKind = (type?.conforms(to: .image) ?? false) ? .image : .file
            ingest(data: data, fileName: url.lastPathComponent, mimeType: mime, kind: kind)
        } catch {
            errorText = "读不了这个文件：\(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    private func ingest(data: Data, fileName: String, mimeType: String, kind: AttachmentKind) {
        do {
            let ref = try AttachmentStore.shared.save(data: data, fileName: fileName, mimeType: mimeType, kind: kind)
            model.pendingAttachments.append(ref)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "保存附件失败。"
        }
    }
}

/// 系统相机/相册的 UIKit 包装：iOS 没有 SwiftUI 原生相机入口。
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
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

    /// 设置页底部显示的版本号，用来区分装的是哪一版。
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
    @State private var showFolderPicker = false
    @State private var mountError: String?
    @State private var showWallpaperSheet = false
    @State private var showPluginsSheet = false

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
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("卡片不透明度")
                            Spacer()
                            Text(String(format: "%.0f%%", model.cardOpacity * 100))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Slider(value: $model.cardOpacity, in: 0.25...1.0)
                    }
                    Button {
                        showWallpaperSheet = true
                    } label: {
                        HStack {
                            Label("壁纸", systemImage: "photo")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    Button {
                        showPluginsSheet = true
                    } label: {
                        HStack {
                            Label("插件", systemImage: "puzzlepiece.extension")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                } header: {
                    Text("外观与扩展")
                } footer: {
                    Text("不透明度调低能多看到一点壁纸，调高字更清楚。壁纸支持照片和视频；插件是 JavaScript 写的工具，放在「文件」App 的 DSH/plugins 里。")
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
                        // 只走最高层弹窗：在设置页 sheet 里再弹一个 sheet 会被 iOS 吞掉。
                        model.pickerRequest = .folders
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
                    TextEditor(text: $model.systemPromptOverride)
                        .font(.system(size: 13))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                    Text("留空就用内置提示词。写完点右上角「保存」生效。也可以在对话里让 agent 用 app_config 改 system_prompt / model / effort / card_opacity 这些。")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                } header: {
                    Text("Agent 能力")
                }

                Section {
                    Text("这是原生 iOS App：模型走 API，工具和文件都在这台设备上跑。iOS 不允许创建子进程，所以没有 shell —— 需要计算用 run_js，需要网页内容用 fetch_url。")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                } header: {
                    Text("能力边界")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            // 设置页做成一层磨砂玻璃：底下透出主界面的壁纸，行背景交给系统行本身。
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { mounts = MountStore.shared.mounts }
            .onChange(of: model.mountsVersion) { _ in
                mounts = MountStore.shared.mounts
            }
            .sheet(isPresented: $showWallpaperSheet) {
                WallpaperPickerView()
            }
            .sheet(isPresented: $showPluginsSheet) {
                NavigationView {
                    PluginListView(host: PluginHost.shared)
                        .navigationTitle("插件")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { showPluginsSheet = false }
                            }
                        }
                }
                .navigationViewStyle(.stack)
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
                        UserDefaults.standard.set(model.systemPromptOverride, forKey: AppModel.systemPromptKey)
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
