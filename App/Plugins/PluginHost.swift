import Foundation
import Combine
import JavaScriptCore

/// 一个插件注册出来的工具（供插件页展示）。
struct PluginToolInfo: Identifiable {
    /// "<插件 id>.<工具名>"。
    let id: String
    /// agent 看到的工具名；与其他工具重名时带插件前缀。
    let name: String
    let description: String
}

/// 一个插件的状态与摘要信息。
struct PluginInfo: Identifiable {
    /// 插件文件名去掉扩展名。
    let id: String
    /// 插件声明的名字；没声明时用文件名。
    var name: String
    var version: String?
    var toolCount: Int
    var enabled: Bool
    /// 加载或部分注册失败的说明；全部正常时为 nil。
    var errorText: String?
}

/// 插件宿主：扫描 Documents/plugins 下的 .js 文件，用 JavaScriptCore 求值并收集
/// registerTool 注册的工具，再交给 agent 调用。
///
/// 只有主线程改 @Published；插件调用在后台队列里执行，跨线程只传字符串。
@MainActor
final class PluginHost: ObservableObject {
    static let shared = PluginHost()

    @Published private(set) var plugins: [PluginInfo] = []

    private var records: [PluginRecord] = []

    init() {
        try? FileManager.default.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        reload()
    }

    /// Documents/plugins；首次访问时自动创建。
    var pluginsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("plugins", isDirectory: true)
    }

    /// 重新扫描插件目录。会重新求值所有插件并重建工具名。
    func reload() {
        let directory = pluginsDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let jsURLs = fileURLs
            .filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var taken = Set(Tools.specs.map { $0.function.name })
        var loadedRecords: [PluginRecord] = []
        for url in jsURLs {
            loadedRecords.append(makeRecord(for: url, taken: &taken))
        }
        records = loadedRecords
        publish()
    }

    /// 开关某个插件；状态写进 UserDefaults。
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = records.firstIndex(where: { $0.info.id == id }) else { return }
        records[index].info.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey(id))
        publish()
    }

    /// 从「文件」App 选中的 URL 拷进插件目录；重名自动加 -1、-2。
    func importPlugin(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard url.pathExtension.lowercased() == "js" else {
            throw ToolFailure.message("只支持 .js 插件文件")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolFailure.message("读不了这个文件：\(error.localizedDescription)")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ToolFailure.message("插件文件不是 UTF-8 文本")
        }

        let directory = pluginsDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        var base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = "plugin"
        }
        var destination = directory.appendingPathComponent(base + ".js", isDirectory: false)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(suffix).js", isDirectory: false)
            suffix += 1
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ToolFailure.message("写入插件目录失败：\(error.localizedDescription)")
        }
        reload()
    }

    /// 删除插件文件，并清掉它的启用状态。
    func deletePlugin(_ id: String) throws {
        guard let record = records.first(where: { $0.info.id == id }) else {
            throw ToolFailure.message("找不到插件：\(id)")
        }
        do {
            try FileManager.default.removeItem(at: record.fileURL)
        } catch {
            throw ToolFailure.message("删除插件失败：\(error.localizedDescription)")
        }
        UserDefaults.standard.removeObject(forKey: Self.enabledKey(id))
        reload()
    }

    /// 已启用插件的工具声明，交给 agent 和工具请求用。
    func toolSpecs() -> [ToolSpec] {
        var specs: [ToolSpec] = []
        for record in records where record.info.enabled {
            for tool in record.tools {
                let parameters = ToolParameters(
                    type: "object",
                    properties: tool.properties,
                    required: tool.required
                )
                let function = ToolSpecFunction(
                    name: tool.agentName,
                    description: tool.description,
                    parameters: parameters
                )
                specs.append(ToolSpec(type: "function", function: function))
            }
        }
        return specs
    }

    /// 某个插件注册的工具清单（插件页展示用）。
    func toolInfos(forPluginId id: String) -> [PluginToolInfo] {
        guard let record = records.first(where: { $0.info.id == id }) else { return [] }
        return record.tools.map { tool in
            PluginToolInfo(
                id: record.info.id + "." + tool.jsName,
                name: tool.agentName,
                description: tool.description
            )
        }
    }

    /// agent 侧是否存在这个插件工具（只看已启用插件）。
    func hasTool(_ name: String) -> Bool {
        findTool(agentName: name) != nil
    }

    /// 执行一个启用的插件工具。
    ///
    /// 每次调用都新建 JSContext 并重新求值插件文件，所以插件之间不共享状态。
    /// JSContext 没有公开的超时或中断 API：插件卡死（比如死循环）会一直占着这次调用的
    /// 后台线程，这里不做额外防护，只能靠启用开关隔离问题插件。
    func call(name: String, arguments: String) async throws -> String {
        guard let target = findTool(agentName: name) else {
            throw ToolFailure.message("没有启用的插件工具：\(name)")
        }

        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let argumentsJSON: String
        if trimmed.isEmpty {
            argumentsJSON = "{}"
        } else {
            guard let data = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else {
                throw ToolFailure.message("插件工具 \(name) 的参数不是合法 JSON")
            }
            argumentsJSON = trimmed
        }

        let source = target.record.source
        let pluginName = target.record.info.name
        let jsName = target.tool.jsName

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try PluginEngine.run(
                        source: source,
                        pluginName: pluginName,
                        toolName: jsName,
                        argumentsJSON: argumentsJSON
                    )
                    continuation.resume(returning: Tools.clip(text))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    continuation.resume(throwing: ToolFailure.message(message))
                }
            }
        }
    }

    private func publish() {
        plugins = records.map { $0.info }
    }

    private func makeRecord(for url: URL, taken: inout Set<String>) -> PluginRecord {
        let id = url.deletingPathExtension().lastPathComponent
        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey(id)) as? Bool ?? true

        func failedRecord(_ message: String) -> PluginRecord {
            PluginRecord(
                info: PluginInfo(
                    id: id,
                    name: id,
                    version: nil,
                    toolCount: 0,
                    enabled: enabled,
                    errorText: message
                ),
                fileURL: url,
                source: "",
                tools: []
            )
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return failedRecord("加载失败：插件文件读不出来（\(error.localizedDescription)）")
        }

        let result = PluginEngine.load(source: source, fileBaseName: id)
        var tools: [PluginTool] = []
        for loaded in result.tools {
            let agentName = Self.uniqueAgentName(loaded.jsName, pluginId: id, taken: &taken)
            tools.append(PluginTool(
                jsName: loaded.jsName,
                agentName: agentName,
                description: loaded.description,
                properties: loaded.properties,
                required: loaded.required
            ))
        }

        let info = PluginInfo(
            id: id,
            name: result.displayName,
            version: result.version,
            toolCount: tools.count,
            enabled: enabled,
            errorText: result.errorText
        )
        return PluginRecord(info: info, fileURL: url, source: source, tools: tools)
    }

    private func findTool(agentName: String) -> (record: PluginRecord, tool: PluginTool)? {
        for record in records where record.info.enabled {
            if let tool = record.tools.first(where: { $0.agentName == agentName }) {
                return (record, tool)
            }
        }
        return nil
    }

    private static func enabledKey(_ id: String) -> String {
        "dsh.plugin.enabled." + id
    }

    /// agent 侧工具名要全局唯一：冲突时加插件前缀，仍然冲突就继续加序号。
    private static func uniqueAgentName(_ toolName: String, pluginId: String, taken: inout Set<String>) -> String {
        var candidate = toolName
        if taken.contains(candidate) {
            candidate = sanitizedPrefix(pluginId) + "__" + toolName
        }
        if candidate.count > 64 {
            candidate = String(candidate.prefix(64))
        }
        var index = 2
        while taken.contains(candidate) {
            let suffix = "_\(index)"
            let room = max(1, 64 - suffix.count)
            let base = candidate.count > room ? String(candidate.prefix(room)) : candidate
            candidate = base + suffix
            index += 1
        }
        taken.insert(candidate)
        return candidate
    }

    private static func sanitizedPrefix(_ pluginId: String) -> String {
        var text = ""
        for scalar in pluginId.unicodeScalars {
            if isASCIILetter(scalar) || (scalar.value >= 48 && scalar.value <= 57) || scalar == "_" {
                text.unicodeScalars.append(scalar)
            } else {
                text.append("_")
            }
        }
        if text.isEmpty {
            text = "plugin"
        }
        if let first = text.unicodeScalars.first, !isASCIILetter(first) {
            text = "p_" + text
        }
        if text.count > 30 {
            text = String(text.prefix(30))
        }
        return text
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }
}

private struct PluginRecord {
    var info: PluginInfo
    let fileURL: URL
    let source: String
    let tools: [PluginTool]
}

private struct PluginTool {
    let jsName: String
    let agentName: String
    let description: String
    let properties: [String: ToolProperty]
    let required: [String]
}

/// JavaScriptCore 这一层：注入原生函数、求值插件文件、跑工具。
/// 只会被 PluginHost 在文件内使用。
private enum PluginEngine {
    struct LoadedTool {
        var jsName: String
        var description: String
        var properties: [String: ToolProperty]
        var required: [String]
    }

    struct LoadResult {
        var displayName: String
        var version: String?
        var tools: [LoadedTool]
        var errorText: String?
    }

    private final class LogBox {
        var lines: [String] = []
    }

    private final class ToolCollector {
        var payloads: [String] = []
        var pluginPayload: String?
    }

    private struct ToolPayload: Decodable {
        var name: String
        var description: String
        var parameters: String
    }

    private struct PluginPayload: Decodable {
        var name: String
        var version: String
    }

    private struct ParameterSchema: Decodable {
        var type: String?
        var properties: [String: ParameterProperty]?
        var required: [String]?
    }

    private struct ParameterProperty: Decodable {
        var type: String?
        var description: String?
    }

    /// 求值插件文件，收集注册信息。不会执行工具本身。
    static func load(source: String, fileBaseName: String) -> LoadResult {
        let logs = LogBox()
        let collector = ToolCollector()
        guard let context = JSContext() else {
            return LoadResult(
                displayName: fileBaseName,
                version: nil,
                tools: [],
                errorText: "加载失败：创建 JavaScript 上下文失败"
            )
        }
        installCommonBlocks(context: context, logs: logs)

        let toolBlock: @convention(block) (Any?) -> Void = { value in
            if let text = PluginEngine.stringValue(value) {
                collector.payloads.append(text)
            }
        }
        context.setObject(toolBlock, forKeyedSubscript: "dshRegisterTool" as NSString)

        let pluginBlock: @convention(block) (Any?) -> Void = { value in
            if let text = PluginEngine.stringValue(value) {
                collector.pluginPayload = text
            }
        }
        context.setObject(pluginBlock, forKeyedSubscript: "dshRegisterPlugin" as NSString)

        context.exception = nil
        _ = context.evaluateScript(prelude)
        if let exception = context.exception {
            return LoadResult(
                displayName: fileBaseName,
                version: nil,
                tools: [],
                errorText: "加载失败：" + exceptionText(exception, logs: logs)
            )
        }

        context.exception = nil
        _ = context.evaluateScript(source)
        let scriptError = context.exception

        var displayName = fileBaseName
        var version: String?
        if let raw = collector.pluginPayload, let payload = decode(PluginPayload.self, from: raw) {
            let declaredName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !declaredName.isEmpty {
                displayName = declaredName
            }
            let declaredVersion = payload.version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !declaredVersion.isEmpty {
                version = declaredVersion
            }
        }

        var tools: [LoadedTool] = []
        var problems: [String] = []
        var seen = Set<String>()
        for raw in collector.payloads {
            guard let payload = decode(ToolPayload.self, from: raw) else {
                problems.append("工具声明不是合法 JSON")
                continue
            }
            let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = toolNameProblem(name) {
                problems.append(problem)
                continue
            }
            if seen.contains(name) {
                problems.append("工具名重复：\(name)")
                continue
            }
            seen.insert(name)

            let text = payload.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = parameters(from: payload.parameters)
            tools.append(LoadedTool(
                jsName: name,
                description: text.isEmpty ? "插件 \(displayName) 注册的工具。" : text,
                properties: parsed.properties,
                required: parsed.required
            ))
        }

        if let exception = scriptError {
            problems.insert("运行出错：" + exceptionText(exception, logs: logs), at: 0)
        }

        return LoadResult(
            displayName: displayName,
            version: version,
            tools: tools,
            errorText: problems.isEmpty ? nil : problems.joined(separator: "\n")
        )
    }

    /// 新建上下文、重新求值插件、调用一个工具的 run。
    static func run(source: String, pluginName: String, toolName: String, argumentsJSON: String) throws -> String {
        let logs = LogBox()
        guard let context = JSContext() else {
            throw ToolFailure.message("插件 \(pluginName) 抛异常：创建 JavaScript 上下文失败")
        }
        installCommonBlocks(context: context, logs: logs)

        // run 模式下插件顶层还会调用 registerTool，这里给它一个不接管结果的空实现。
        let noopBlock: @convention(block) (Any?) -> Void = { _ in }
        context.setObject(noopBlock, forKeyedSubscript: "dshRegisterTool" as NSString)
        context.setObject(noopBlock, forKeyedSubscript: "dshRegisterPlugin" as NSString)
        context.setObject(argumentsJSON as NSString, forKeyedSubscript: "dshToolArgsJSON" as NSString)

        context.exception = nil
        _ = context.evaluateScript(prelude)
        if let exception = context.exception {
            throw ToolFailure.message("插件 \(pluginName) 抛异常：" + exceptionText(exception, logs: logs))
        }

        context.exception = nil
        _ = context.evaluateScript(source)
        if let exception = context.exception {
            throw ToolFailure.message("插件 \(pluginName) 抛异常：" + exceptionText(exception, logs: logs))
        }

        context.exception = nil
        let value = context.evaluateScript("dshRunTool(\"\(toolName)\")")
        if let exception = context.exception {
            throw ToolFailure.message("插件 \(pluginName) 抛异常：" + exceptionText(exception, logs: logs))
        }
        guard let text = value?.toString() else {
            throw ToolFailure.message("插件 \(pluginName) 抛异常：工具 \(toolName) 没有返回值")
        }
        return text
    }

    private static func installCommonBlocks(context: JSContext, logs: LogBox) {
        let logBlock: @convention(block) (Any?) -> Void = { value in
            let text = PluginEngine.stringValue(value) ?? "undefined"
            logs.lines.append(String(text.prefix(400)))
        }
        context.setObject(logBlock, forKeyedSubscript: "dshConsoleLog" as NSString)

        let readBlock: @convention(block) (Any?) -> Any? = { value in
            let path = PluginEngine.stringValue(value) ?? ""
            do {
                return PluginEngine.okEnvelope(try PluginEngine.readText(path: path))
            } catch {
                return PluginEngine.errorEnvelope(PluginEngine.message(for: error))
            }
        }
        context.setObject(readBlock, forKeyedSubscript: "dshReadFile" as NSString)

        let writeBlock: @convention(block) (Any?, Any?) -> Any? = { value, contentValue in
            let path = PluginEngine.stringValue(value) ?? ""
            let content = PluginEngine.stringValue(contentValue) ?? ""
            do {
                return PluginEngine.okEnvelope(try PluginEngine.writeText(path: path, text: content))
            } catch {
                return PluginEngine.errorEnvelope(PluginEngine.message(for: error))
            }
        }
        context.setObject(writeBlock, forKeyedSubscript: "dshWriteFile" as NSString)

        let listBlock: @convention(block) (Any?) -> Any? = { value in
            let path = PluginEngine.stringValue(value) ?? "."
            do {
                return PluginEngine.okEnvelope(try PluginEngine.listDirectory(path: path))
            } catch {
                return PluginEngine.errorEnvelope(PluginEngine.message(for: error))
            }
        }
        context.setObject(listBlock, forKeyedSubscript: "dshListDir" as NSString)

        let nowBlock: @convention(block) () -> Any? = {
            return PluginEngine.nowText()
        }
        context.setObject(nowBlock, forKeyedSubscript: "dshNow" as NSString)
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let text = value as? String {
            return text
        }
        if let jsValue = value as? JSValue {
            return jsValue.toString()
        }
        return String(describing: value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func parameters(from raw: String) -> (properties: [String: ToolProperty], required: [String]) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let schema = decode(ParameterSchema.self, from: trimmed) else {
            return ([:], [])
        }
        var properties: [String: ToolProperty] = [:]
        for (key, value) in schema.properties ?? [:] {
            var type = (value.type ?? "string").trimmingCharacters(in: .whitespacesAndNewlines)
            if type.isEmpty {
                type = "string"
            }
            properties[key] = ToolProperty(type: type, description: value.description ?? "")
        }
        var seen = Set<String>()
        var required: [String] = []
        for key in schema.required ?? [] {
            if properties[key] != nil && !seen.contains(key) {
                seen.insert(key)
                required.append(key)
            }
        }
        return (properties, required)
    }

    private static func toolNameProblem(_ name: String) -> String? {
        if name.isEmpty {
            return "工具名不能为空"
        }
        if name.count > 40 {
            return "工具名太长（最多 40 个字符）：\(name)"
        }
        guard let first = name.unicodeScalars.first, isASCIILetter(first) else {
            return "工具名必须以英文字母开头：\(name)"
        }
        for scalar in name.unicodeScalars {
            if isASCIILetter(scalar) || (scalar.value >= 48 && scalar.value <= 57) || scalar == "_" {
                continue
            }
            return "工具名只能包含英文字母、数字和下划线：\(name)"
        }
        return nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func exceptionText(_ exception: JSValue, logs: LogBox) -> String {
        var text = exception.toString() ?? "未知错误"
        if let message = exception.forProperty("message")?.toString(), !message.isEmpty {
            text = message
        }
        let tail = logs.lines.suffix(5)
        if !tail.isEmpty {
            text += "\nconsole 输出（最后 \(tail.count) 行）：\n" + tail.joined(separator: "\n")
        }
        return text
    }

    // MARK: - 文件与时间

    private static func readText(path: String) throws -> String {
        let url = try Workspace.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolFailure.message("文件不存在：\(Workspace.relativePath(of: url))")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ToolFailure.message("读取文件失败：\(error.localizedDescription)")
        }
    }

    private static func writeText(path: String, text: String) throws -> String {
        let url = try Workspace.resolve(path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "已写入 \(Workspace.relativePath(of: url))（\(text.count) 个字符）"
        } catch {
            throw ToolFailure.message("写入文件失败：\(error.localizedDescription)")
        }
    }

    private static func listDirectory(path: String) throws -> String {
        let url = try Workspace.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolFailure.message("目录不存在：\(Workspace.relativePath(of: url))")
        }
        guard isDirectory.boolValue else {
            throw ToolFailure.message("这不是目录：\(Workspace.relativePath(of: url))")
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let names = entries
            .map { $0.lastPathComponent }
            .sorted()
        if names.isEmpty {
            return "（空目录）"
        }
        return names.joined(separator: "\n")
    }

    private static func nowText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func okEnvelope(_ value: String) -> String {
        envelope(ok: true, value: value, error: "")
    }

    private static func errorEnvelope(_ message: String) -> String {
        envelope(ok: false, value: "", error: message)
    }

    private static func envelope(ok: Bool, value: String, error: String) -> String {
        var payload: [String: Any] = ["ok": ok]
        if !value.isEmpty {
            payload["value"] = value
        }
        if !error.isEmpty {
            payload["error"] = error
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return ok ? "{\"ok\":true,\"value\":\"\"}" : "{\"ok\":false,\"error\":\"内部错误\"}"
        }
        return text
    }

    // MARK: - JS 预置代码

    // 插件文件里能直接用：console、readFile、writeFile、listDir、now、jsonStringify、
    // registerTool、registerPlugin。原生函数返回 JSON 信封，由这里拆开抛错。
    private static let prelude = """
var __dshJoin = function (args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) {
        var item = args[i];
        if (typeof item === "string") {
            parts.push(item);
        } else {
            try {
                parts.push(JSON.stringify(item));
            } catch (error) {
                parts.push(String(item));
            }
        }
    }
    return parts.join(" ");
};

var __dshLog = function (level, args) {
    dshConsoleLog("[" + level + "] " + __dshJoin(args));
};

var console = {
    log: function () { __dshLog("log", arguments); },
    info: function () { __dshLog("info", arguments); },
    warn: function () { __dshLog("warn", arguments); },
    error: function () { __dshLog("error", arguments); },
    debug: function () { __dshLog("debug", arguments); }
};

var __dshTools = {};

var registerTool = function (definition) {
    if (!definition || typeof definition !== "object") {
        throw new Error("registerTool 需要一个对象参数");
    }
    var name = String(definition.name || "");
    var description = String(definition.description || "");
    var parameters = definition.parameters;
    if (typeof parameters === "string") {
        parameters = JSON.parse(parameters);
    }
    if (!parameters || typeof parameters !== "object") {
        parameters = { type: "object", properties: {}, required: [] };
    }
    if (typeof definition.run !== "function") {
        throw new Error("工具 " + name + " 缺少 run 函数");
    }
    __dshTools[name] = definition;
    dshRegisterTool(JSON.stringify({
        name: name,
        description: description,
        parameters: JSON.stringify(parameters)
    }));
};

var registerPlugin = function (definition) {
    if (!definition || typeof definition !== "object") {
        return;
    }
    dshRegisterPlugin(JSON.stringify({
        name: String(definition.name || ""),
        version: String(definition.version || "")
    }));
};

var readFile = function (path) {
    var envelope = JSON.parse(dshReadFile(String(path)));
    if (!envelope.ok) {
        throw new Error(envelope.error);
    }
    return envelope.value;
};

var writeFile = function (path, text) {
    var envelope = JSON.parse(dshWriteFile(String(path), String(text)));
    if (!envelope.ok) {
        throw new Error(envelope.error);
    }
    return envelope.value;
};

var listDir = function (path) {
    var envelope = JSON.parse(dshListDir(String(path)));
    if (!envelope.ok) {
        throw new Error(envelope.error);
    }
    return envelope.value;
};

var now = function () {
    return dshNow();
};

var jsonStringify = function (value) {
    return JSON.stringify(value, null, 2);
};

var dshRunTool = function (toolName) {
    var definition = __dshTools[toolName];
    if (!definition) {
        throw new Error("没有注册工具：" + toolName);
    }
    var argumentsValue = {};
    if (typeof dshToolArgsJSON === "string" && dshToolArgsJSON.length > 0) {
        argumentsValue = JSON.parse(dshToolArgsJSON);
    }
    var result = definition.run(argumentsValue);
    if (result === undefined || result === null) {
        return "";
    }
    if (typeof result === "string") {
        return result;
    }
    return JSON.stringify(result, null, 2);
};
"""
}
