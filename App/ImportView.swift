import SwiftUI

/// 导入 DeepSeek App 导出的对话包。页面独立成 View，设置页只负责挂入口。
struct ImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    @State private var importing = false
    @State private var resultText: String?
    @State private var failed = false

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        introSection
                        pickerSection
                        resultSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("导入对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(Theme.accent)
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(mode: .files) { urls in
                    showPicker = false
                    guard let url = urls.first else { return }
                    startImport(from: url)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// 说明卡：先讲清边界，用户才不会以为导入会覆盖现有对话。
    private var introSection: some View {
        SettingsSection(title: "会怎么导入", note: "只新增，不动现有会话") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在 DeepSeek App 里「设置 → 数据导出」下载 zip，用「文件」App 存到这台 iPad 上，再点下面的按钮选它。")
                    Text("导入的对话会作为新会话加到列表最上面，你现在已有的会话一条都不会动。")
                    Text("只导入对话正文：图片、搜到的网页、思考过程这轮暂不导入。")
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pickerSection: some View {
        SettingsSection(title: "导出包", note: "zip") {
            SettingsCard {
                Button {
                    showPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                        Text(importing ? "正在导入…" : "选择导出包…")
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                        if importing {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                    .foregroundColor(importing ? Theme.textTertiary : Theme.accent)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .disabled(importing)
            }
        }
    }

    /// 成功和失败都用同一块地方显示，用户不用去别处找原因。
    private var resultSection: some View {
        SettingsSection(title: "结果") {
            SettingsCard {
                Text(resultText ?? "还没有导入过。")
                    .font(.system(size: 13))
                    .foregroundColor(resultColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var resultColor: Color {
        guard resultText != nil else { return Theme.textTertiary }
        return failed ? Theme.danger : Theme.success
    }

    /// 解析是同步的（要解开 130 MB 的 zip），先让「正在导入」画出来再调用，
    /// 否则点下去界面直接僵住，用户会以为按钮没反应。
    private func startImport(from url: URL) {
        importing = true
        failed = false
        resultText = nil
        Task { @MainActor in
            await Task.yield()
            let text = model.importDeepSeekSessions(from: url)
            resultText = text
            failed = text.hasPrefix("导入失败")
            importing = false
        }
    }
}
