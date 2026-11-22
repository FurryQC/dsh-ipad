import Foundation
import JavaScriptCore
import UIKit

enum ToolFailure: Error {
    case message(String)
}

extension ToolFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// App 沙盒里的工作目录。所有工具只能在这个目录里读写。
struct Workspace {
    static let folderName = "workspace"

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(folderName, isDirectory: true)
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
    }

    /// 把 URL 变回模型看得懂的路径：工作目录里是相对路径，外部授权目录是 `mount:名字/子路径`。
    static func relativePath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if path == base { return "." }
        if path.hasPrefix(base + "/") {
            var relative = String(path.dropFirst(base.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            return relative
        }
        for mount in MountStore.shared.mounts {
            guard let mountURL = try? MountStore.shared.resolve(name: mount.name) else { continue }
            let mountPath = mountURL.standardizedFileURL.path
            if path == mountPath { return "mount:" + mount.name }
            if path.hasPrefix(mountPath + "/") {
                var relative = String(path.dropFirst(mountPath.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
                return "mount:" + mount.name + "/" + relative
            }
        }
        return url.lastPathComponent
    }

    /// 把模型给的路径解析成 URL。
    ///
    /// `mount:<名字>/...` 走用户授权过的外部目录；其余一律相对工作目录，
    /// 两条路都做前缀校验，`..` 一律拒绝。
    static func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "." || path == "./" { return root }
        if path.hasPrefix("mount:") {
            return try resolveInMount(String(path.dropFirst("mount:".count)))
        }

        while path.hasPrefix("/") { path.removeFirst() }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("..") {
            throw ToolFailure.message("路径里不能包含 ..，所有操作只能在工作目录或已授权的挂载目录里进行")
        }

        var url = root
        for part in parts where !part.isEmpty && part != "." {
            url.appendPathComponent(part, isDirectory: false)
        }

        let resolved = url.standardizedFileURL
        let base = root.standardizedFileURL.path
        let target = resolved.path
        guard target == base || target.hasPrefix(base + "/") else {
            throw ToolFailure.message("路径越界：\(raw)")
        }
        return resolved
    }

    private static func resolveInMount(_ rest: String) throws -> URL {
        var text = rest
        while text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty else {
            throw ToolFailure.message("mount: 后面要跟目录名，例如 mount:下载/清单.txt")
        }
        let parts = text.split(separator: "/").map(String.init)
        if parts.contains("..") {
            throw ToolFailure.message("路径里不能包含 ..")
        }
        guard let name = parts.first, !name.isEmpty else {
            throw ToolFailure.message("mount: 后面要跟目录名")
        }
        let baseURL = try MountStore.shared.resolve(name: name)
        var url = baseURL
        for part in parts.dropFirst() where !part.isEmpty && part != "." {
            url.appendPathComponent(part, isDirectory: false)
        }
        let resolved = url.standardizedFileURL
        let base = baseURL.standardizedFileURL.path
        let target = resolved.path
        guard target == base || target.hasPrefix(base + "/") else {
            throw ToolFailure.message("路径越界：mount:\(rest)")
        }
        return resolved
    }
}

enum Tools {
    static let outputLimit = 30000

    // MARK: - 工具清单

    static var specs: [ToolSpec] {
        [
            spec(
                "list_dir",
                "列出工作目录里某个目录的内容（名字、是否目录、字节数）。",
                ["path": ("string", "相对工作目录的路径，省略表示工作目录根。")],
                required: []
            ),
            spec(
                "read_file",
                "读取工作目录里一个文本文件的内容。",
                ["path": ("string", "相对工作目录的文件路径。"),
                 "max_lines": ("integer", "最多读多少行，默认 2000。")],
                required: ["path"]
            ),
            spec(
                "write_file",
                "把文本写入工作目录里的文件（会覆盖同名文件，自动创建上级目录）。",
                ["path": ("string", "相对工作目录的文件路径。"),
                 "content": ("string", "要写入的完整文本。")],
                required: ["path", "content"]
            ),
            spec(
                "make_dir",
                "在工作目录里新建目录（含上级目录）。",
                ["path": ("string", "相对工作目录的目录路径。")],
                required: ["path"]
            ),
            spec(
                "delete_path",
                "删除工作目录里的文件或目录（目录会连同内容一起删）。",
                ["path": ("string", "相对工作目录的路径。")],
                required: ["path"]
            ),
            spec(
                "move_path",
                "移动或重命名工作目录里的文件/目录。",
                ["from": ("string", "源路径。"),
                 "to": ("string", "目标路径。")],
                required: ["from", "to"]
            ),
            spec(
                "edit_file",
                "把文件里的一段文本替换成新文本（和桌面端的编辑工具一样按原文匹配，不重写整个文件）。",
                ["path": ("string", "文件路径。"),
                 "old_text": ("string", "要被替换掉的原文本，必须和文件里一模一样（含缩进）。"),
                 "new_text": ("string", "替换成的新文本，空字符串表示删除这段。"),
                 "replace_all": ("boolean", "这段文本出现多次时是否全部替换，默认 false（出现多次会报错让你给更长上下文）。")],
                required: ["path", "old_text", "new_text"]
            ),
            spec(
                "search_files",
                "在目录里按正则搜索文本，返回命中的 路径:行号: 那一行。用来在一个项目里找代码或找文件。",
                ["pattern": ("string", "正则表达式，例如 TODO 或 func\\s+main。"),
                 "path": ("string", "从哪个目录开始搜，省略表示工作目录根。"),
                 "max_results": ("integer", "最多返回多少条，默认 50。")],
                required: ["pattern"]
            ),
            spec(
                "file_info",
                "查一个路径是否存在、是文件还是目录、多大、什么时候改的。",
                ["path": ("string", "要查的路径。")],
                required: ["path"]
            ),
            spec(
                "copy_path",
                "复制文件或目录（源不动）。",
                ["from": ("string", "源路径。"),
                 "to": ("string", "目标路径。")],
                required: ["from", "to"]
            ),
            spec(
                "fetch_url",
                "抓取一个 http/https 网址，返回正文文本（HTML 会去掉标签）。",
                ["url": ("string", "完整网址，必须带 http:// 或 https://。")],
                required: ["url"]
            ),
            spec(
                "run_js",
                "在 JavaScriptCore 里执行一段 JS，返回 console.log 的输出。适合算数、处理文本、跑小脚本。",
                ["code": ("string", "要执行的 JavaScript 源码，用 console.log 输出。")],
                required: ["code"]
            ),
            spec(
                "now",
                "拿到当前的日期、时间和时区。",
                [:],
                required: []
            ),
            spec(
                "open_url",
                "在设备上打开一个网址或别的 App 的 URL scheme（例如 https://…、shortcuts://、safari://、maps://），会切到那个 App。",
                ["url": ("string", "完整 URL，没有 scheme 时按 https:// 处理。")],
                required: ["url"]
            ),
            spec(
                "app_config",
                "读取或修改这个 App 自己的设置（模型、推理等级、卡片不透明度、轮数上限、开跑前提醒、系统提示词）。action=get 列出当前值；action=set 需要 key 和 value。",
                ["action": ("string", "get 或 set，默认 get。"),
                 "key": ("string", "set 时的键：model / effort / base_url / card_opacity / max_rounds / warn_before_run / system_prompt。"),
                 "value": ("string", "set 时的新值，统一按字符串传（布尔用 true/false）。")],
                required: []
            ),
        ]
    }

    private static func spec(_ name: String, _ description: String,
                             _ properties: [String: (String, String)],
                             required: [String]) -> ToolSpec {
        var props: [String: ToolProperty] = [:]
        for (key, value) in properties {
            props[key] = ToolProperty(type: value.0, description: value.1)
        }
        let parameters = ToolParameters(type: "object", properties: props, required: required)
        return ToolSpec(type: "function",
                        function: ToolSpecFunction(name: name, description: description, parameters: parameters))
    }

    // MARK: - 执行

    static func execute(name: String, arguments: String) async -> String {
        do {
            let args = try parseArguments(arguments)
            switch name {
            case "list_dir":   return try listDir(args)
            case "read_file":  return try readFile(args)
            case "write_file": return try writeFile(args)
            case "make_dir":   return try makeDir(args)
            case "delete_path": return try deletePath(args)
            case "move_path":  return try movePath(args)
            case "edit_file":  return try editFile(args)
            case "search_files": return try searchFiles(args)
            case "file_info":  return try fileInfo(args)
            case "copy_path":  return try copyPath(args)
            case "fetch_url":  return try await fetchURL(args)
            case "run_js":     return try runJS(args)
            case "now":        return nowString()
            case "open_url":   return try await openURL(args)
            case "app_config": return try appConfig(args)
            default:           return "错误：没有名为 \(name) 的工具。可用工具：list_dir, read_file, write_file, edit_file, make_dir, delete_path, move_path, copy_path, search_files, file_info, fetch_url, run_js, now, open_url, app_config"
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return "错误：" + text
        }
    }

    // MARK: - 打开别的 App / 改本 App 设置

    /// AppModel 订阅这个通知，把 UserDefaults 里的新值同步回界面状态。
    static let configChanged = Notification.Name("com.dsh.ipad.configChanged")

    private static func openURL(_ args: [String: Any]) async throws -> String {
        let raw = try string(args, "url").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            throw ToolFailure.message("open_url 需要 url 参数")
        }
        let normalized: String
        if raw.contains("://") || raw.hasPrefix("mailto:") || raw.hasPrefix("tel:") {
            normalized = raw
        } else {
            normalized = "https://" + raw
        }
        guard let url = URL(string: normalized) else {
            throw ToolFailure.message("不是合法的 URL：\(raw)")
        }
        // UIApplication.open 只能在主线程调，回调也在主线程。
        let opened: Bool = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                UIApplication.shared.open(url, options: [:]) { ok in cont.resume(returning: ok) }
            }
        }
        if opened { return "已经用系统打开 \(normalized)" }
        throw ToolFailure.message("系统打不开 \(normalized) —— 可能这台设备没装对应的 App，或者 scheme 不对。")
    }

    private static func appConfig(_ args: [String: Any]) throws -> String {
        let defaults = UserDefaults.standard
        let action = try string(args, "action", fallback: "get").lowercased()
        let rows: [(String, String, String)] = [
            ("model", "dsh.model", "模型名，例如 deepseek-flash"),
            ("effort", "dsh.effort", "推理等级 off / low / high / max"),
            ("base_url", "dsh.baseURL", "接口地址，默认 https://api.deepseek.com/anthropic"),
            ("card_opacity", "dsh.cardOpacity", "卡片不透明度 0.25 ~ 1.0"),
            ("max_rounds", "dsh.maxRounds", "一次任务最多几轮工具 4 ~ 80"),
            ("warn_before_run", "dsh.warnBeforeRun", "开跑前是否提醒别切走 true / false"),
            ("system_prompt", "dsh.systemPromptOverride", "自定义系统提示词，空字符串表示用内置的"),
        ]
        if action == "get" {
            var lines = ["这个 App 的当前设置："]
            for (name, key, description) in rows {
                let value = defaults.object(forKey: key).map { String(describing: $0) } ?? "（还没设置，用默认值）"
                lines.append("- \(name) = \(value)    # \(description)")
            }
            return lines.joined(separator: "\n")
        }
        guard action == "set" else {
            throw ToolFailure.message("app_config 的 action 只能是 get 或 set")
        }
        let key = try string(args, "key").trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            throw ToolFailure.message("set 需要 key 参数")
        }
        let value = try string(args, "value")
        guard let row = rows.first(where: { $0.0 == key }) else {
            throw ToolFailure.message("没有这个设置项：\(key)。可用的是：" + rows.map { $0.0 }.joined(separator: ", "))
        }
        switch key {
        case "model", "base_url":
            defaults.set(value, forKey: row.1)
        case "effort":
            let lowered = value.lowercased()
            guard ["off", "low", "high", "max"].contains(lowered) else {
                throw ToolFailure.message("effort 只能是 off / low / high / max")
            }
            defaults.set(lowered, forKey: row.1)
        case "card_opacity":
            guard let number = Double(value), number >= 0.25, number <= 1.0 else {
                throw ToolFailure.message("card_opacity 要 0.25 到 1.0 之间的数字")
            }
            defaults.set(number, forKey: row.1)
        case "max_rounds":
            guard let number = Int(value), number >= 4, number <= 80 else {
                throw ToolFailure.message("max_rounds 要 4 到 80 之间的整数")
            }
            defaults.set(number, forKey: row.1)
        case "warn_before_run":
            let lowered = value.lowercased()
            guard lowered == "true" || lowered == "false" else {
                throw ToolFailure.message("warn_before_run 用 true 或 false")
            }
            defaults.set(lowered == "true", forKey: row.1)
        default:
            defaults.set(value, forKey: row.1)
        }
        NotificationCenter.default.post(name: configChanged, object: nil)
        return "已改：\(key) = \(value)。界面会自动刷新，下一轮对话生效。"
    }

    // MARK: - 参数

    private static func parseArguments(_ raw: String) throws -> [String: Any] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        guard let data = text.data(using: .utf8) else {
            throw ToolFailure.message("工具参数不是合法的 UTF-8")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ToolFailure.message("工具参数不是合法 JSON：\(text.prefix(200))")
        }
        guard let dict = object as? [String: Any] else {
            throw ToolFailure.message("工具参数必须是 JSON 对象")
        }
        return dict
    }

    private static func string(_ args: [String: Any], _ key: String, fallback: String? = nil) throws -> String {
        if let value = args[key] as? String { return value }
        if let fallback = fallback { return fallback }
        throw ToolFailure.message("缺少参数 \(key)")
    }

    private static func intValue(_ args: [String: Any], _ key: String, fallback: Int) -> Int {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? Double { return Int(value) }
        if let value = args[key] as? String, let parsed = Int(value) { return parsed }
        return fallback
    }

    static func clip(_ text: String) -> String {
        if text.count <= outputLimit { return text }
        return String(text.prefix(outputLimit)) + "\n…（已截断，原文 \(text.count) 个字符）"
    }

    // MARK: - 各工具实现

    private static func listDir(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path", fallback: ".")
        let url = try Workspace.resolve(path)
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolFailure.message("没有这个路径：\(path)")
        }
        guard isDirectory.boolValue else {
            throw ToolFailure.message("这不是目录：\(path)")
        }

        let items = try manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        )
        let title = Workspace.relativePath(of: url)
        if items.isEmpty { return "\(title)\n（空目录）" }

        let lines = items
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { item -> String in
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    return item.lastPathComponent + "/"
                }
                return "\(item.lastPathComponent)   \(values?.fileSize ?? 0) B"
            }
        return "\(title)\n" + lines.joined(separator: "\n")
    }

    private static func readFile(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let maxLines = max(1, intValue(args, "max_lines", fallback: 2000))
        let url = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure.message("没有这个文件：\(path)")
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolFailure.message("这是二进制文件（\(data.count) 字节），不能当文本读：\(path)")
        }
        let lines = text.components(separatedBy: "\n")
        if lines.count > maxLines {
            let head = lines.prefix(maxLines).joined(separator: "\n")
            return "\(path)（共 \(lines.count) 行，只给出前 \(maxLines) 行）\n" + clip(head)
        }
        return clip(text.isEmpty ? "（空文件）" : text)
    }

    private static func writeFile(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let content = try string(args, "content")
        let url = try Workspace.resolve(path)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        guard let data = content.data(using: .utf8) else {
            throw ToolFailure.message("内容无法编码成 UTF-8")
        }
        try data.write(to: url, options: .atomic)
        return "已写入 \(Workspace.relativePath(of: url))（\(data.count) 字节）"
    }

    private static func makeDir(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let url = try Workspace.resolve(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return "已创建目录 \(Workspace.relativePath(of: url))"
    }

    private static func deletePath(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let url = try Workspace.resolve(path)
        let base = Workspace.root.standardizedFileURL.path
        guard url.standardizedFileURL.path != base else {
            throw ToolFailure.message("不能删除工作目录本身")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure.message("没有这个路径：\(path)")
        }
        try FileManager.default.removeItem(at: url)
        return "已删除 \(path)"
    }

    private static func movePath(_ args: [String: Any]) throws -> String {
        let from = try string(args, "from")
        let to = try string(args, "to")
        let source = try Workspace.resolve(from)
        let target = try Workspace.resolve(to)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ToolFailure.message("没有这个路径：\(from)")
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.moveItem(at: source, to: target)
        return "已移动 \(from) → \(to)"
    }

    /// 按原文替换：和桌面端的编辑工具同一套语义（默认要求唯一匹配）。
    private static func editFile(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let oldText = try string(args, "old_text")
        let newText = try string(args, "new_text", fallback: "")
        let replaceAll = (args["replace_all"] as? Bool) ?? false

        guard !oldText.isEmpty else {
            throw ToolFailure.message("old_text 不能为空，没法定位要改哪一段")
        }
        let url = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure.message("没有这个文件：\(path)")
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolFailure.message("这是二进制文件，不能按文本改：\(path)")
        }
        let occurrences = text.components(separatedBy: oldText).count - 1
        if occurrences == 0 {
            throw ToolFailure.message("文件里没有这段原文，什么都没改：\(path)。先用 read_file 看一眼现在的实际内容。")
        }
        if occurrences > 1 && !replaceAll {
            throw ToolFailure.message("这段原文在 \(path) 里出现了 \(occurrences) 次，不知道该改哪一处。给更长的上下文，或者把 replace_all 设成 true。")
        }

        let updated: String
        if replaceAll {
            updated = text.replacingOccurrences(of: oldText, with: newText)
        } else if let range = text.range(of: oldText) {
            updated = text.replacingCharacters(in: range, with: newText)
        } else {
            updated = text
        }
        guard let out = updated.data(using: .utf8) else {
            throw ToolFailure.message("改完的内容没法编码成 UTF-8")
        }
        try out.write(to: url, options: .atomic)
        let changed = replaceAll ? occurrences : 1
        return "已修改 \(Workspace.relativePath(of: url))（替换 \(changed) 处，现在 \(out.count) 字节）"
    }

    /// 按正则搜目录里的文本行。跳过隐藏文件、二进制和超大文件。
    private static func searchFiles(_ args: [String: Any]) throws -> String {
        let pattern = try string(args, "pattern")
        let path = try string(args, "path", fallback: ".")
        let maxResults = max(1, intValue(args, "max_results", fallback: 50))

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw ToolFailure.message("正则写得不对：\(error.localizedDescription)")
        }

        let start = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: start.path) else {
            throw ToolFailure.message("没有这个路径：\(path)")
        }

        var hits: [String] = []
        var scanned = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let manager = FileManager.default

        func scan(_ file: URL) {
            guard hits.count < maxResults else { return }
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let children = (try? manager.contentsOfDirectory(at: file,
                                                                 includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    scan(child)
                }
                return
            }
            if (values?.fileSize ?? 0) > 1_500_000 { return }
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { return }
            scanned += 1
            let display = Workspace.relativePath(of: file)
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if hits.count >= maxResults { return }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    hits.append("\(display):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        scan(start)
        if hits.isEmpty {
            return "没有匹配 \(pattern)（扫了 \(scanned) 个文本文件）"
        }
        let tail = hits.count >= maxResults ? "\n…（到上限 \(maxResults) 条了，可能还有更多）" : ""
        return "匹配 \(hits.count) 条（扫了 \(scanned) 个文本文件）\n" + hits.joined(separator: "\n") + tail
    }

    private static func fileInfo(_ args: [String: Any]) throws -> String {
        let path = try string(args, "path")
        let url = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "\(path) 不存在"
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let isDirectory = values?.isDirectory ?? false
        var lines = ["路径：\(Workspace.relativePath(of: url))", "类型：\(isDirectory ? "目录" : "文件")"]
        if !isDirectory, let size = values?.fileSize {
            lines.append("大小：\(size) 字节")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        if let modified = values?.contentModificationDate {
            lines.append("修改时间：\(formatter.string(from: modified))")
        }
        if let created = values?.creationDate {
            lines.append("创建时间：\(formatter.string(from: created))")
        }
        if isDirectory {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            lines.append("直接子项：\(children.count) 个")
        }
        return lines.joined(separator: "\n")
    }

    private static func copyPath(_ args: [String: Any]) throws -> String {
        let from = try string(args, "from")
        let to = try string(args, "to")
        let source = try Workspace.resolve(from)
        let target = try Workspace.resolve(to)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ToolFailure.message("没有这个路径：\(from)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        try FileManager.default.copyItem(at: source, to: target)
        return "已复制 \(from) → \(to)"
    }

    private static func fetchURL(_ args: [String: Any]) async throws -> String {
        let raw = try string(args, "url")
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ToolFailure.message("只支持完整的 http/https 网址，收到：\(raw)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) DSH/1.0",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let mime = http?.mimeType ?? "unknown"
        let rawText = String(data: data, encoding: .utf8) ?? "（不是 UTF-8 文本，共 \(data.count) 字节）"
        let body = mime.contains("html") ? stripHTML(rawText) : rawText
        return "HTTP \(status) \(mime)\n" + clip(body)
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runJS(_ args: [String: Any]) throws -> String {
        let code = try string(args, "code")
        guard let context = JSContext() else {
            throw ToolFailure.message("创建 JavaScript 上下文失败")
        }

        final class Output {
            var lines: [String] = []
        }
        let output = Output()

        let log: @convention(block) (Any?) -> Void = { value in
            if let jsValue = value as? JSValue {
                output.lines.append(jsValue.toString() ?? "undefined")
            } else if let value = value {
                output.lines.append("\(value)")
            } else {
                output.lines.append("undefined")
            }
        }
        context.setObject(log, forKeyedSubscript: "consoleLog" as NSString)

        let prelude = """
        var __join = function (args) {
          var parts = [];
          for (var i = 0; i < args.length; i++) {
            var a = args[i];
            if (typeof a === 'object' && a !== null) {
              try { parts.push(JSON.stringify(a)); } catch (e) { parts.push(String(a)); }
            } else {
              parts.push(String(a));
            }
          }
          return parts.join(' ');
        };
        var console = {
          log: function () { consoleLog(__join(arguments)); },
          info: function () { consoleLog(__join(arguments)); },
          warn: function () { consoleLog('WARN: ' + __join(arguments)); },
          error: function () { consoleLog('ERROR: ' + __join(arguments)); }
        };
        """
        context.evaluateScript(prelude)
        _ = context.evaluateScript(code)

        if let exception = context.exception, let message = exception.toString() {
            let logs = output.lines.isEmpty ? "" : "\n--- console ---\n" + output.lines.joined(separator: "\n")
            return "JavaScript 抛出异常：" + message + logs
        }

        let text = output.lines.joined(separator: "\n")
        return clip(text.isEmpty ? "（执行完成，没有任何 console 输出）" : text)
    }

    private static func nowString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let absolute = formatter.string(from: Date())
        let iso = ISO8601DateFormatter().string(from: Date())
        return "\(absolute)\n\(iso)\n时区：\(TimeZone.current.identifier)"
    }
}
