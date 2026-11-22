import SwiftUI
import ReplayKit
import UserNotifications

/// 屏幕识别（直播捕捉）设置页。
///
/// 真正抓画面的是 `BroadcastExtension`：用户从系统广播选择器启动它之后，
/// 扩展每 N 秒截一帧交给 DeepSeek，再把结果发成系统通知。
/// 这一页只负责配置（写进 App Group）和把用户引到系统广播入口。
struct WatchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = WatchShared.load()
    @State private var lastResult: String = ""
    @State private var lastAt: Date?
    @State private var diag = WatchShared.readDiag()
    @State private var status: String = ""
    @State private var savedHint = false

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        statusCard
                        diagnosticCard
                        startCard
                        configCard
                        saveRow
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("屏幕识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationViewStyle(.stack)
            .onAppear {
                config = WatchShared.load()
                requestNotificationPermission()
                refreshLastResult()
                diag = WatchShared.readDiag()
            }
            .onReceive(timer) { _ in
                refreshLastResult()
                diag = WatchShared.readDiag()
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(config.enabled ? Theme.success : Theme.textTertiary)
                    .frame(width: 8, height: 8)
                Text(config.enabled ? "已启用（等你在系统里开始广播）" : "未启用")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
            }
            Divider().overlay(Theme.stroke)
            Text("最近一条结果")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            Text(lastResult.isEmpty ? "还没有。开始广播后会每 \(Int(config.intervalSeconds)) 秒来一条。" : lastResult)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastAt {
                Text(relative(lastAt))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    /// 广播「开启了但什么都没发生」时，靠这一张卡定位卡在哪一步。
    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("诊断")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Spacer()
                Button {
                    diag = WatchShared.readDiag()
                } label: {
                    Text("刷新")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
            }
            Divider().overlay(Theme.stroke)
            diagRow("App Group", WatchShared.containerDiagnostics(),
                    good: WatchShared.groupAvailable && WatchShared.groupProbe() == "ok")
            diagRow("容器路径", WatchShared.containerPath, good: WatchShared.containerURL != nil)
            diagRow("配置", diag.configEnabled ? "已启用" : "未启用 / 没读到", good: diag.configEnabled)
            diagRow("扩展心跳", heartbeatText, good: heartbeatFresh)
            diagRow("收到帧", "\(diag.frames)", good: diag.frames > 0)
            diagRow("已发送识别", "\(diag.sent)", good: diag.sent > 0)
            if !diag.lastError.isEmpty {
                Text(diag.lastError)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("读法：帧数是 0 → 广播没真正跑起来或扩展没拿到画面；帧数在涨但发送是 0 → 配置读不到（App Group）；发送在涨但没通知 → 通知权限。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private var heartbeatFresh: Bool {
        diag.heartbeat > 0 && Date().timeIntervalSince1970 - diag.heartbeat < 15
    }

    private var heartbeatText: String {
        guard diag.heartbeat > 0 else { return "还没有（扩展没写过状态）" }
        let at = Date(timeIntervalSince1970: diag.heartbeat)
        return relative(at)
    }

    private func diagRow(_ title: String, _ value: String, good: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(good ? Theme.success : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("开始捕捉")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("点下面这个按钮 → 在系统弹层里选「DSH 屏幕识别」→ 开始直播。返回任何 App 都会继续识别。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                BroadcastPicker()
                    .frame(width: 190, height: 52)
                Spacer()
            }
            // 点圆钮的同时把配置写进共享容器，省掉「忘了点保存」这一步。
            .simultaneousGesture(TapGesture().onEnded { save() })
            Text("停止：从屏幕右上角红色胶囊点一下，或者回到系统控制中心停止录制。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("识别设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)

            Toggle(isOn: $config.enabled) {
                Text("启用截帧识别")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("间隔")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Text(String(format: "%.0f 秒", config.intervalSeconds))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                }
                Slider(value: $config.intervalSeconds, in: 1...5, step: 1)
                    .tint(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("提示词（发给模型的任务）")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                TextEditor(text: $config.prompt)
                    .font(.system(size: 13))
                    .frame(minHeight: 84)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("推理强度")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                Picker("推理强度", selection: $config.effort) {
                    ForEach(["off", "low", "high", "max"], id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                TextField("deepseek-flash", text: $config.model)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            }

            Toggle(isOn: $config.notify) {
                Text("结果发成系统通知")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
            }
            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private var saveRow: some View {
        VStack(spacing: 8) {
            Button {
                save()
            } label: {
                Text("保存设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent))
            }
            if savedHint {
                Text("已保存。改完要重新开始一次广播才会生效。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
            if !status.isEmpty {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    private func save() {
        // 扩展读不到钥匙串，所以把 key 复制进 App Group 容器。
        let key = Keychain.loadAPIKey()
        if !key.isEmpty { config.apiKey = key }
        WatchShared.save(config)
        savedHint = true
        if config.apiKey.isEmpty {
            status = "还没填 API key：先回设置页填一次，再回来保存。"
        } else {
            status = ""
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func refreshLastResult() {
        guard let result = WatchShared.lastResult() else { return }
        lastResult = result.text
        lastAt = result.at
    }

    private func relative(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return "更新于 " + formatter.string(from: date)
    }
}

/// 系统屏幕广播按钮。Apple 自己的控件，点击后弹出「选择要直播的 App / 扩展」。
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 190, height: 52))
        view.showsMicrophoneButton = false
        view.preferredExtension = WatchShared.extensionBundleID
        return view
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
