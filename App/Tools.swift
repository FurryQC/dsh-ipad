import Foundation
import JavaScriptCore

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

    static func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        var relative = String(path.dropFirst(base.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? "." : relative
    }

    /// 把模型给的相对路径解析到工作目录内；越界直接拒绝。
    static func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "." || path == "./" { return root }

        while path.hasPrefix("/") { path.removeFirst() }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains("..") {
            throw ToolFailure.message("路径里不能包含 ..，所有操作只能在工作目录内进行")
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
            case "fetch_url":  return try await fetchURL(args)
            case "run_js":     return try runJS(args)
            case "now":        return nowString()
            default:           return "错误：没有名为 \(name) 的工具。可用工具：list_dir, read_file, write_file, make_dir, delete_path, move_path, fetch_url, run_js, now"
            }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return "错误：" + text
        }
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
