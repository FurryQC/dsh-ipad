import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SessionList()
        } detail: {
            ChatScreen()
        }
        .onChange(of: scenePhase) { phase in
            model.handleScenePhase(phase)
        }
        .alert("任务运行期间别切走", isPresented: Binding(
            get: { model.showSwitchWarning },
            set: { newValue in if !newValue { model.cancelSwitchWarning() } }
        )) {
            Button("开始任务") { model.confirmSwitchWarning() }
            Button("取消", role: .cancel) { model.cancelSwitchWarning() }
        } message: {
            Text("iPadOS 会在你切到别的 App 后挂起本 App，正在跑的请求会被切断。任务跑完再去做别的；需要查资料就在本 App 里让它用 fetch_url。")
        }
    }
}

// MARK: - 会话列表

struct SessionList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.sessions) { session in
                Button {
                    model.select(session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    session.id == model.currentSessionID
                        ? Color.accentColor.opacity(0.14)
                        : Color.clear
                )
            }
            .onDelete { indexSet in
                // 先取出 id 再删：边遍历 indexSet 边删会让后面的下标越界。
                let ids = indexSet.map { model.sessions[$0].id }
                ids.forEach { model.deleteSession($0) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DSH")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newSession()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(model.isRunning)
            }
        }
    }
}

// MARK: - 聊天页

struct ChatScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isRunning {
                runningBanner
            }
            messageList
            composer
        }
        .background(Color(.systemBackground))
        .navigationTitle(model.currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
    }

    private var runningBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(model.statusLine.isEmpty ? "运行中…" : model.statusLine)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("请留在本 App")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.16))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.currentItems.isEmpty {
                        emptyState
                    }
                    ForEach(model.currentItems) { item in
                        MessageRow(item: item)
                            .id(item.id)
                    }
                    if model.isRunning && !model.streamPreview.isEmpty {
                        AssistantBubble(text: model.streamPreview, streaming: true)
                            .id("stream-preview")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: model.currentItems.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: model.streamPreview) { _ in
                // 流式文字只改 streamPreview、不改条数，不盯这个就滚不到最新一行。
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if model.isRunning && !model.streamPreview.isEmpty {
            withAnimation { proxy.scrollTo("stream-preview", anchor: .bottom) }
            return
        }
        guard let last = model.currentItems.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundColor(.accentColor)
            Text("说点什么，它自己动手")
                .font(.title3.weight(.semibold))
            Text("模型通过你的 DeepSeek API key 调用；读写文件、抓网页、跑 JS 都在这一台 iPad 上完成。工作目录在「文件」App 的 DSH 文件夹里。")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(.top, 30)
        .padding(.horizontal, 4)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = model.errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        model.errorText = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $draft)
                    .frame(minHeight: 40, maxHeight: 110)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )

                if model.isRunning {
                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.red)
                    }
                } else {
                    Button {
                        let text = draft
                        draft = ""
                        model.send(text)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(
                                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.secondary
                                    : Color.accentColor
                            )
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - 消息行

struct MessageRow: View {
    let item: ChatItem

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.accentColor)
                    )
                    .textSelection(.enabled)
            }
        case .assistant:
            AssistantBubble(text: item.text, streaming: false)
        case .tool:
            ToolCard(item: item)
        }
    }
}

struct AssistantBubble: View {
    let text: String
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("…").foregroundColor(.secondary)
                }
            } else {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if streaming {
                Text("生成中")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

struct ToolCard: View {
    let item: ChatItem
    @State private var expanded = false

    private var summary: String {
        let firstLine = item.text.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.isEmpty ? "（无输出）" : firstLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: item.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundColor(item.isError ? .orange : .secondary)
                    Text(item.toolName ?? "工具")
                        .font(.subheadline.weight(.medium))
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                // 纵向滚动 + 自动换行。横向 ScrollView 里 Text 不会换行，长行只能左右拖。
                ScrollView(.vertical, showsIndicators: true) {
                    Text(item.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showKey = false
    @State private var copied = false
    @State private var keyError: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 8) {
                        if showKey {
                            TextField("sk-…", text: $model.apiKey)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("sk-…", text: $model.apiKey)
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("接口地址", text: $model.baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("模型", text: $model.model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("DeepSeek API")
                } footer: {
                    Text("key 存在系统钥匙串里，不写进会话文件。地址默认 https://api.deepseek.com，也可以填中转地址。")
                }

                Section {
                    Stepper("最多 \(model.maxRounds) 轮工具调用", value: $model.maxRounds, in: 4...80)
                    Toggle("开跑前提醒别切走", isOn: $model.warnBeforeRun)
                } header: {
                    Text("运行")
                } footer: {
                    Text("一轮 = 模型回一次 + 执行它要的工具。提醒只在每次打开 App 后第一次发消息时弹一次。")
                }

                Section {
                    Text(Workspace.root.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(copied ? "已复制路径" : "复制工作目录路径") {
                        UIPasteboard.general.string = Workspace.root.path
                        copied = true
                    }
                } header: {
                    Text("工作目录")
                } footer: {
                    Text("所有文件都在这里，可以在「文件」App 的 我的 iPad → DSH 里看到。App 卸载后一起没了。")
                }

                Section {
                    Text("没有 shell：iOS 不允许 App 起子进程，所以不能跑命令行、不能编译代码。需要计算或处理文本时，它会在 JavaScriptCore 里跑 JS。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("能力边界")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        // key 只在点完成时写钥匙串，输入过程中不动它。
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
    }
}
