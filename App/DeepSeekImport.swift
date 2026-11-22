import Compression
import Foundation

// MARK: - ZIP 读取

/// 读导出包时可能出的错。文案直接显示给用户，所以写中文。
enum ZipError: LocalizedError {
    case unreadable(String)
    case notArchive
    case entryMissing(String)
    case unsupportedCompression(UInt16)
    case corruptEntry(String)
    case decompressFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "打不开 \(name)"
        case .notArchive:
            return "这不是一个有效的 zip 导出包"
        case .entryMissing(let name):
            return "导出包里缺少 \(name)"
        case .unsupportedCompression(let method):
            return "导出包里用了不支持的压缩方式（\(method)）"
        case .corruptEntry(let name):
            return "导出包里的 \(name) 读坏了"
        case .decompressFailed(let name):
            return "\(name) 解不开，文件可能没下载完整"
        }
    }
}

/// 小端读 16 位。Data 由 FileHandle 读出来，索引都是从 0 开始的连续整数。
private func zipUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    let start = data.startIndex + offset
    return UInt16(data[start]) | (UInt16(data[start + 1]) << 8)
}

/// 小端读 32 位。
private func zipUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    let start = data.startIndex + offset
    return UInt32(data[start])
        | (UInt32(data[start + 1]) << 8)
        | (UInt32(data[start + 2]) << 16)
        | (UInt32(data[start + 3]) << 24)
}

/// 中央目录里的一项。只留解压要用的字段，别把整份目录常驻在内存里。
private struct ZipEntry {
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

/// 最小 zip 读取器：只支持 stored（0）和 deflate（8），DeepSeek 导出包只有这两种。
/// 全程按需 seek —— 真导出包 130 MB、最大的会话 json 2 MB，整包读进内存会直接把 iPad 撑爆。
final class ZipReader {
    /// 条目名，顺序与中央目录一致。调用方只用来判断某个文件在不在。
    var names: [String] = []

    private let handle: FileHandle
    private let fileSize: Int
    private var entries: [String: ZipEntry] = [:]

    init(url: URL) throws {
        let opened: FileHandle
        do {
            opened = try FileHandle(forReadingFrom: url)
        } catch {
            throw ZipError.unreadable(url.lastPathComponent)
        }
        handle = opened
        do {
            let size = Int((try? opened.seekToEnd()) ?? 0)
            // 22 是 EOCD 固定部分的长度，比它还小的文件不可能是 zip。
            guard size > 22 else {
                throw ZipError.notArchive
            }
            fileSize = size
            let parsed = try ZipReader.parseCentralDirectory(handle: opened, fileSize: size)
            entries = parsed.entries
            names = parsed.names
        } catch {
            // init 已经拿到 FileHandle，失败路径得自己关，否则文件会一直被占着。
            try? opened.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    /// 读某个条目的原始字节（已解压）。
    func data(for name: String) throws -> Data {
        guard let entry = entries[name] else {
            throw ZipError.entryMissing(name)
        }
        guard entry.method == 0 || entry.method == 8 else {
            throw ZipError.unsupportedCompression(entry.method)
        }
        guard entry.localHeaderOffset >= 0,
              entry.localHeaderOffset + 30 <= fileSize,
              entry.compressedSize >= 0,
              entry.uncompressedSize >= 0 else {
            throw ZipError.corruptEntry(name)
        }
        let header = try ZipReader.read(handle: handle, offset: entry.localHeaderOffset, count: 30)
        guard zipUInt32(header, 0) == 0x04034b50 else {
            throw ZipError.corruptEntry(name)
        }
        // 本地头的文件名/extra 长度可能和中央目录记的不一样，zip 规范以本地头为准。
        let nameLength = Int(zipUInt16(header, 26))
        let extraLength = Int(zipUInt16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard dataOffset + entry.compressedSize <= fileSize else {
            throw ZipError.corruptEntry(name)
        }
        let payload = try ZipReader.read(handle: handle, offset: dataOffset, count: entry.compressedSize)
        if entry.method == 0 {
            // 存储态没有压缩：长度对不上说明目录坏了，错的数据不如不返回。
            guard payload.count == entry.uncompressedSize else {
                throw ZipError.corruptEntry(name)
            }
            return payload
        }
        return try inflate(payload, uncompressedSize: entry.uncompressedSize, name: name)
    }

    // MARK: 解析

    private static func parseCentralDirectory(handle: FileHandle, fileSize: Int) throws -> (entries: [String: ZipEntry], names: [String]) {
        // EOCD 后面的注释最长 65535 字节，所以签名只可能出现在最后 65557 字节里。
        let tailLength = min(fileSize, 65_557)
        let tail = try read(handle: handle, offset: fileSize - tailLength, count: tailLength)
        guard let eocd = findEndOfCentralDirectory(in: tail) else {
            throw ZipError.notArchive
        }
        let directorySize = Int(zipUInt32(tail, eocd + 12))
        let directoryOffset = Int(zipUInt32(tail, eocd + 16))
        guard directorySize >= 0, directoryOffset >= 0,
              directoryOffset + directorySize <= fileSize else {
            throw ZipError.notArchive
        }
        let directory = try read(handle: handle, offset: directoryOffset, count: directorySize)
        var entries: [String: ZipEntry] = [:]
        var names: [String] = []
        var position = 0
        while position + 46 <= directory.count {
            guard zipUInt32(directory, position) == 0x02014b50 else {
                throw ZipError.notArchive
            }
            let method = zipUInt16(directory, position + 10)
            let compressedSize = Int(zipUInt32(directory, position + 20))
            let uncompressedSize = Int(zipUInt32(directory, position + 24))
            let nameLength = Int(zipUInt16(directory, position + 28))
            let extraLength = Int(zipUInt16(directory, position + 30))
            let commentLength = Int(zipUInt16(directory, position + 32))
            let localHeaderOffset = Int(zipUInt32(directory, position + 42))
            guard position + 46 + nameLength <= directory.count else {
                throw ZipError.notArchive
            }
            let nameStart = directory.startIndex + position + 46
            let nameData = Data(directory[nameStart ..< (nameStart + nameLength)])
            // 条目名基本是 ASCII；不是合法 UTF-8 就退回 Latin-1，别让一个怪名字毁掉整包。
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            entries[name] = ZipEntry(method: method,
                                     compressedSize: compressedSize,
                                     uncompressedSize: uncompressedSize,
                                     localHeaderOffset: localHeaderOffset)
            names.append(name)
            position += 46 + nameLength + extraLength + commentLength
        }
        return (entries, names)
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var offset = data.count - 22
        while offset >= 0 {
            if zipUInt32(data, offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// 精确读 count 个字节。FileHandle.read 可能分多次返回，所以循环读满。
    private static func read(handle: FileHandle, offset: Int, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            throw ZipError.corruptEntry("第 \(offset) 字节")
        }
        var data = Data()
        data.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(remaining, 1 << 20))
            } catch {
                throw ZipError.corruptEntry("第 \(offset) 字节")
            }
            guard let chunk = chunk, !chunk.isEmpty else { break }
            data.append(chunk)
            remaining -= chunk.count
        }
        guard data.count == count else {
            throw ZipError.corruptEntry("第 \(offset) 字节")
        }
        return data
    }

    /// 解 raw DEFLATE：Apple 的 COMPRESSION_ZLIB 就是 zip 用的那种裸流，别再想加 zlib 头。
    private func inflate(_ payload: Data, uncompressedSize: Int, name: String) throws -> Data {
        // 坏掉的目录项可能声明一个巨大的未压缩大小，别照着它去分配内存。
        guard uncompressedSize <= 64 * 1024 * 1024 else {
            throw ZipError.corruptEntry(name)
        }
        if uncompressedSize == 0 {
            return Data()
        }
        var output = [UInt8](repeating: 0, count: uncompressedSize)
        let written: Int = payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.withUnsafeMutableBufferPointer { target -> Int in
                guard let targetBase = target.baseAddress else { return 0 }
                return compression_decode_buffer(targetBase,
                                                 target.count,
                                                 sourceBase,
                                                 source.count,
                                                 nil,
                                                 COMPRESSION_ZLIB)
            }
        }
        guard written == uncompressedSize else {
            throw ZipError.decompressFailed(name)
        }
        return Data(output)
    }
}

// MARK: - DeepSeek 导出包

/// 导入结果：转好的会话，以及因为没有正文被跳过的会话数。
struct DeepSeekImportResult {
    var sessions: [ChatSession]
    var skipped: Int
}

/// 解析导出包时的失败。文案直接给用户看。
enum DeepSeekImportError: LocalizedError {
    case missingIndex
    case badIndex
    case sessionFailed(index: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingIndex:
            return "这不是 DeepSeek 的导出包（缺 chat_session_index.json）"
        case .badIndex:
            return "导出包的对话索引读不出来，可能没下载完整"
        case .sessionFailed(let index, let reason):
            return "第 \(index) 个会话解析失败：\(reason)"
        }
    }
}

/// 索引里的一项。只用到「去哪找会话文件」和兜底标题/时间。
private struct DeepSeekIndexEntry: Decodable {
    let id: String
    let title: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
    }
}

/// 单个会话文件。messages 之外的字段只留标题当兜底。
private struct DeepSeekSessionFile: Decodable {
    let title: String?
    let updatedAt: String?
    let messages: [DeepSeekMessage]?

    private enum CodingKeys: String, CodingKey {
        case title, messages
        case updatedAt = "updated_at"
    }
}

/// 一条消息。accumulated_token_usage 的类型由服务端定，用 try? 兜住 ——
/// 别让一处字段结构变化把整份导出读废。
private struct DeepSeekMessage: Decodable {
    let role: String?
    let accumulatedTokenUsage: Int?
    let fragments: [DeepSeekFragment]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        accumulatedTokenUsage = (try? container.decodeIfPresent(Int.self, forKey: .accumulatedTokenUsage)) ?? nil
        fragments = (try? container.decodeIfPresent([DeepSeekFragment].self, forKey: .fragments)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case role, fragments
        case accumulatedTokenUsage = "accumulated_token_usage"
    }
}

/// 消息片段。只要 type 和 content：REQUEST 是用户正文，RESPONSE 是助手正文，其余跳过。
private struct DeepSeekFragment: Decodable {
    let type: String?
    let content: String?
}

/// 把 DeepSeek App 的导出包读成我们自己的会话。
enum DeepSeekImport {
    /// 读整个导出包。图片、搜到的网页、思考过程这轮都不导入。
    static func load(from url: URL) throws -> DeepSeekImportResult {
        let zip = try ZipReader(url: url)
        guard zip.names.contains("chat_session_index.json") else {
            throw DeepSeekImportError.missingIndex
        }
        let indexData = try zip.data(for: "chat_session_index.json")
        let index: [DeepSeekIndexEntry]
        do {
            index = try JSONDecoder().decode([DeepSeekIndexEntry].self, from: indexData)
        } catch {
            throw DeepSeekImportError.badIndex
        }
        var sessions: [ChatSession] = []
        var skipped = 0
        for (offset, entry) in index.enumerated() {
            let path = "chat_sessions/\(entry.id).json"
            // 索引里列了、包里却没有：跳过这一条，不要因为它把整包导入打断。
            guard zip.names.contains(path) else {
                skipped += 1
                continue
            }
            do {
                let data = try zip.data(for: path)
                let file = try JSONDecoder().decode(DeepSeekSessionFile.self, from: data)
                let mapped = map(file: file, entry: entry)
                // 整条会话都是空的（全被跳过）就别塞进列表，那只是个空气泡。
                guard !mapped.items.isEmpty else {
                    skipped += 1
                    continue
                }
                sessions.append(ChatSession(id: UUID(),
                                            title: mapped.title,
                                            mode: .chat,
                                            items: mapped.items,
                                            updatedAt: mapped.updatedAt,
                                            lastRunSeconds: nil,
                                            tokensIn: 0,
                                            tokensOut: mapped.tokenOut,
                                            pinned: false))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "格式不认识"
                throw DeepSeekImportError.sessionFailed(index: offset + 1, reason: reason)
            }
        }
        return DeepSeekImportResult(sessions: sessions, skipped: skipped)
    }

    /// 映射的中间产物：标题已经缀好「（导入）」，日期已经解析过。
    private struct MappedSession {
        var title: String
        var items: [ChatItem]
        var updatedAt: Date
        var tokenOut: Int
    }

    private static func map(file: DeepSeekSessionFile, entry: DeepSeekIndexEntry) -> MappedSession {
        var items: [ChatItem] = []
        var tokenOut = 0
        for message in file.messages ?? [] {
            tokenOut += message.accumulatedTokenUsage ?? 0
            let fragments = message.fragments ?? []
            let role = message.role ?? ""
            let chatRole: ChatRole
            let text: String
            if role == "USER" {
                chatRole = .user
                text = userText(fragments)
            } else if role == "ASSISTANT" {
                chatRole = .assistant
                text = assistantText(fragments)
            } else {
                // 导出包里还有 system / tool 之类的角色，我们的会话用不上。
                continue
            }
            // 只有思考、搜索、安全提示片段的消息没有正文，导进来就是一个空气泡。
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            items.append(ChatItem(role: chatRole, text: text))
        }
        let rawTitle = firstNonEmpty(file.title, entry.title) ?? "导入的对话"
        let updatedAt = parseDate(file.updatedAt) ?? parseDate(entry.updatedAt) ?? Date()
        return MappedSession(title: rawTitle + "（导入）",
                             items: items,
                             updatedAt: updatedAt,
                             tokenOut: tokenOut)
    }

    private static func userText(_ fragments: [DeepSeekFragment]) -> String {
        fragments.first(where: { $0.type == "REQUEST" })?.content ?? ""
    }

    /// 一条助手消息可能拆成多个 RESPONSE 片段，按顺序拼回一段正文。
    private static func assistantText(_ fragments: [DeepSeekFragment]) -> String {
        fragments.filter { $0.type == "RESPONSE" }
            .compactMap { $0.content }
            .joined()
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value = value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// 导出包里的时间是 ISO8601 带毫秒（"2026-11-21T17:15:32.436Z"）。
    /// 两种格式都试：同一个包里偶尔会有不带毫秒的时间。
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseDate(_ text: String?) -> Date? {
        guard let text = text, !text.isEmpty else { return nil }
        if let date = isoFormatterWithFractional.date(from: text) {
            return date
        }
        return isoFormatterPlain.date(from: text)
    }
}
