import SwiftUI
import UIKit

/// 设置页。自绘卡片而不是 Form —— Form 在深色壁纸上是一整片死黑，
/// 把分组拆成悬浮的毛玻璃卡片，背景能透出来，也和聊天页同一套语言。
struct SettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showKey = false
    @State private var showWallpaper = false
    @State private var showPlugins = false
    @State private var mounts: [MountedFolder] = []
    @State private var keyError: String?
    @State private var savedHint = false

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        overviewCard
                        modelSection
                        runSection
                        appearanceSection
                        fileSection
                        agentSection
                        credentialSection
                        footerSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { mounts = MountStore.shared.mounts }
        .onChange(of: model.mountsVersion) { _ in mounts = MountStore.shared.mounts }
        .sheet(isPresented: $showWallpaper) {
            WallpaperPickerView()
        }
        .sheet(isPresented: $showPlugins) {
            NavigationView {
                PluginListView(host: PluginHost.shared)
            }
        }
        .alert("API key 没存上", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button("知道了", role: .cancel) { keyError = nil }
        } message: {
            Text(keyError ?? "")
        }
    }

    // MARK: - 概览

    private var overviewCard: some View {
        SettingsCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("累计用量")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                    Text(tokenCountText(model.totalTokens))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundColor(Theme.textPrimary)
                    Text("token · 全部会话")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text("本会话")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                    Text(tokenCountText(model.currentSession?.tokensTotal ?? 0))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    Text("\(model.sessions.count) 个会话")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
            }
        }
    }

    private func tokenCountText(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", Double(value) / 1_000_000)
        }
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return "\(value)"
    }

    // MARK: - 模型与推理

    private var modelSection: some View {
        SettingsSection(title: "模型与推理") {
            SettingsCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("模型").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                        Spacer()
                        Menu {
                            if model.availableModels.isEmpty {
                                Text("点下面的按钮拉取列表")
                            } else {
                                ForEach(model.availableModels) { option in
                                    Button {
                                        model.model = option.id
                                    } label: {
                                        Label(option.name, systemImage: model.model == option.id ? "checkmark" : "")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(model.model)
                                    .font(.system(size: 14, weight: .medium))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(Theme.accent)
                        }
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    HStack(spacing: 8) {
                        Text("推理").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                        Spacer()
                        ForEach(MessagesAPI.efforts, id: \.self) { effort in
                            Button {
                                model.reasoningEffort = effort
                            } label: {
                                Text(effort)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(model.reasoningEffort == effort ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(model.reasoningEffort == effort ? Theme.accentSoft : Color.white.opacity(0.07))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    Button {
                        Task { await model.fetchModels() }
                    } label: {
                        HStack {
                            Text("刷新模型列表").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                            Spacer()
                            if model.isFetchingModels {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 运行

    private var runSection: some View {
        SettingsSection(title: "运行") {
            SettingsCard {
                VStack(spacing: 0) {
                    HStack {
                        Text("单次最多轮数").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                        Spacer()
                        Stepper("\(model.maxRounds)", value: $model.maxRounds, in: 4...80)
                            .labelsHidden()
                        Text("\(model.maxRounds)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    .padding(.vertical, 10)

                    SettingsDivider()

                    Toggle(isOn: $model.warnBeforeRun) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开跑前提醒别切走").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                            Text("工作模式下每次任务第一次运行时弹一次")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        SettingsSection(title: "外观") {
            SettingsCard {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("卡片不透明度").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("\(Int(model.cardOpacity * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                        Slider(value: $model.cardOpacity, in: 0.25...1.0)
                            .tint(Theme.accent)
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    Button {
                        showWallpaper = true
                    } label: {
                        SettingsNavRow(title: "壁纸", detail: "照片 · 视频 · 网页")
                    }
                    .buttonStyle(.plain)

                    SettingsDivider()

                    Button {
                        showPlugins = true
                    } label: {
                        SettingsNavRow(title: "插件", detail: "\(PluginHost.shared.plugins.count) 个 .js 插件")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 文件

    private var fileSection: some View {
        SettingsSection(title: "文件与权限") {
            SettingsCard {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("工作目录").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                            Text("DSH/Documents/workspace")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                        Button {
                            UIPasteboard.general.string = Workspace.root.path
                            model.toast = "路径已复制"
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    Button {
                        model.pickerRequest = .folders
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.accent)
                            Text("添加外部文件夹").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if mounts.isEmpty {
                        Text("还没授权任何外部文件夹。iOS 只允许 App 访问自己沙盒里的文件，外面的目录必须由你手动选一次。")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)
                    } else {
                        ForEach(mounts) { mount in
                            SettingsDivider()
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mount.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(Theme.textPrimary)
                                    Text("mount:\(mount.name)/…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                Spacer()
                                Button {
                                    try? MountStore.shared.remove(id: mount.id)
                                    mounts = MountStore.shared.mounts
                                    model.mountsVersion += 1
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Theme.danger)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Agent 能力

    private var agentSection: some View {
        SettingsSection(title: "Agent 能力", note: "留空就用内置提示词。改这里等于直接改它的行为准则") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $model.systemPromptOverride)
                        .font(.system(size: 13))
                        .frame(minHeight: 132)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(Theme.textPrimary)
                        .background(Color.clear)
                    HStack {
                        Text(model.systemPromptOverride.isEmpty ? "当前：内置提示词" : "当前：自定义（\(model.systemPromptOverride.count) 字）")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                        Spacer()
                        if !model.systemPromptOverride.isEmpty {
                            Button("清空") { model.systemPromptOverride = "" }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.danger)
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - 凭据

    private var credentialSection: some View {
        SettingsSection(title: "DeepSeek") {
            SettingsCard {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Group {
                            if showKey {
                                TextField("sk-…", text: $model.apiKey)
                            } else {
                                SecureField("sk-…", text: $model.apiKey)
                            }
                        }
                        .font(.system(size: 14))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("接口地址").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                        TextField("https://api.deepseek.com/anthropic", text: $model.baseURL)
                            .font(.system(size: 13))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.vertical, 12)

                    SettingsDivider()

                    Button {
                        UserDefaults.standard.set(model.systemPromptOverride, forKey: AppModel.systemPromptKey)
                        if Keychain.saveAPIKey(model.apiKey) {
                            savedHint = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { savedHint = false }
                        } else {
                            keyError = "钥匙串写入失败，key 没存上。重新签名后再试。"
                        }
                    } label: {
                        HStack {
                            Text(savedHint ? "已保存" : "保存")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(savedHint ? Theme.success : Theme.accent)
                            Spacer()
                            Image(systemName: savedHint ? "checkmark.circle.fill" : "tray.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(savedHint ? Theme.success : Theme.accent)
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 页脚

    private var footerSection: some View {
        VStack(spacing: 6) {
            Text("DSH for iPad · \(appVersion)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Text("模型跑在 DeepSeek 云端，工具和文件在本机执行。iOS 没有 shell，也不能读写别的 App 的私有目录。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - 卡片与行

/// 分组标题 + 卡片。标题放外面，卡片之间才有呼吸。
struct SettingsSection<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.leading, 4)
            content
        }
    }
}

/// 毛玻璃卡片。比 Form 的 section 圆角更大、更薄，壁纸能透上来。
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
    }
}

/// 右侧带 chevron 的跳转行，和普通设置行保持同一高度节奏。
struct SettingsNavRow: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(Theme.textPrimary)
            Spacer()
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.vertical, 12)
    }
}
