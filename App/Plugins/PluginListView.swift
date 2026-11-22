import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 插件管理页：插件目录提示、插件列表、启用开关，以及导入、删除、刷新。
///
/// 外层导航由调用方提供，例如 `NavigationView { PluginListView(host: .shared) }`。
struct PluginListView: View {
    @ObservedObject var host: PluginHost

    @State private var isImporting = false
    @State private var showAlert = false
    @State private var alertText = ""
    @State private var hasCopiedPath = false

    var body: some View {
        List {
            Section {
                Text(verbatim: host.pluginsDirectory.path)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                Button(action: { copyPath() }) {
                    Label(hasCopiedPath ? "已拷贝路径" : "拷贝插件目录路径", systemImage: "doc.on.doc")
                }
                Text("在「文件」App 里进入「我的 iPad › 本应用 › plugins」放 .js 插件，或者点右上角 + 直接导入。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("插件目录")
            }

            Section {
                if host.plugins.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有插件")
                            .foregroundColor(.secondary)
                        Text("把 .js 插件文件放进上面的目录，或者点右上角 + 导入，再点刷新。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(host.plugins) { plugin in
                        PluginRow(plugin: plugin, host: host)
                    }
                    .onDelete(perform: deletePlugins)
                }
            } header: {
                Text("已加载插件")
            } footer: {
                Text("插件工具只在开启后才会出现在对话可用工具里；改完文件点右上角刷新重新加载。")
                    .font(.footnote)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { isImporting = true }) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("导入插件")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { host.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新插件")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertText), dismissButton: .default(Text("好")))
        }
    }

    /// 允许选中的类型：.js 优先，再加上纯文本和任意数据，避免系统认不出 .js 时选不了。
    private var importTypes: [UTType] {
        var types: [UTType] = []
        if let jsType = UTType(filenameExtension: "js") {
            types.append(jsType)
        }
        types.append(.plainText)
        types.append(.data)
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try host.importPlugin(from: url)
            } catch {
                presentAlert(message: message(for: error))
            }
        case .failure(let error):
            presentAlert(message: "选择文件失败：\(error.localizedDescription)")
        }
    }

    private func deletePlugins(at offsets: IndexSet) {
        let targets = offsets.map { host.plugins[$0] }
        for plugin in targets {
            do {
                try host.deletePlugin(plugin.id)
            } catch {
                presentAlert(message: message(for: error))
            }
        }
    }

    private func copyPath() {
        UIPasteboard.general.string = host.pluginsDirectory.path
        hasCopiedPath = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            hasCopiedPath = false
        }
    }

    private func presentAlert(message: String) {
        alertText = message
        showAlert = true
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// 单个插件行：名称、版本、工具数、错误提示和启用开关。
private struct PluginRow: View {
    let plugin: PluginInfo
    @ObservedObject var host: PluginHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(plugin.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { plugin.enabled },
                    set: { newValue in host.setEnabled(plugin.id, newValue) }
                ))
                .labelsHidden()
            }
            Text(detailText)
                .font(.footnote)
                .foregroundColor(.secondary)
            if let errorText = plugin.errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !toolNames.isEmpty {
                Text("工具：" + toolNames.joined(separator: "、"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var detailText: String {
        var parts: [String] = []
        if let version = plugin.version, !version.isEmpty {
            parts.append("v" + version)
        } else {
            parts.append("未声明版本")
        }
        parts.append("\(plugin.toolCount) 个工具")
        return parts.joined(separator: " · ")
    }

    private var toolNames: [String] {
        host.toolInfos(forPluginId: plugin.id).map { $0.name }
    }
}
