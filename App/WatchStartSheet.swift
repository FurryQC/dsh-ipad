import SwiftUI

/// 屏幕识别的第一次使用说明。iOS 不允许 App 自己开始录屏，只能让用户点一次
/// 系统广播按钮，所以这一页把「为什么」和「点哪儿」一次说清楚。
struct WatchStartSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var interval: Int {
        let value = WatchShared.load().intervalSeconds
        return max(1, min(5, Int(value.rounded())))
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        explanationCard
                        startCard
                        hintCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle("屏幕识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accent)
                Text("为什么需要这个权限")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            Text("屏幕上的内容只存在于系统里，App 读不到。iOS 唯一允许的通道是系统广播（ReplayKit）：由你亲手点一次「开始直播」，系统才会把屏幕画面交给这个 App。\n\n画面只在本机切成截图、每 \(interval) 秒取一帧发给 DeepSeek 的 flash 模型看，推理等级固定为 off，不占你平时用的推理设置。识别结果会以系统通知弹出，同时也记进当前对话，结束后自动折叠成「屏幕识别信息」。")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var startCard: some View {
        VStack(spacing: 12) {
            BroadcastPicker()
                .frame(width: 56, height: 56)
            Text("点这个圆钮开始")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("系统会弹一个「开始直播」确认页，确认即可。结束后从控制中心点红条停止。")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
        )
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("识别中不要锁屏，锁屏后直播会断", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.warning)
            Text("当前状态：\(model.watchActive ? "已就绪，等待你点开始按钮" : "未开启")")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}
