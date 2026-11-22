import Combine
import Foundation
import UIKit

/// 附件是图片还是普通文件。两者落盘策略不同，所以建索引时就要分开。
enum AttachmentKind: String, Codable {
    case image
    case file
}

/// 一条已落盘的附件引用。会话历史只存这个结构，正文按需从磁盘读，
/// 否则每次保存历史都要把 base64 再写一遍。
struct AttachmentRef: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: AttachmentKind
    var fileName: String
    var mimeType: String
    var byteCount: Int
    /// Documents/attachments 下的真实文件名。存储名和展示名是两回事，路径只能用这个拼。
    var storedName: String
}

/// 附件失败都带中文描述，聊天界面可以直接显示，不用再翻译一遍。
enum AttachmentError: LocalizedError {
    case notAnImage
    case tooLarge
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnImage:
            return "这个文件不是图片，或者图片已经损坏。"
        case .tooLarge:
            return "文件超过 20 MB，无法上传。"
        case .writeFailed(let detail):
            return "保存附件失败：\(detail)"
        }
    }
}

/// 附件落盘、缩略图与读取的唯一入口。
///
/// 放在 Documents 下而不是临时目录：会话历史里存的是引用，重启后还要能找回文件。
@MainActor
final class AttachmentStore: ObservableObject {
    static let shared: AttachmentStore = AttachmentStore()

    /// 超过上限直接报错，不截断：悄悄截断会让用户以为整份文件传上去了。
    private static let maxByteCount = 20 * 1024 * 1024
    /// 原图长边上限。模型侧还会再压，本机先缩小可以明显减少上传体积。
    private static let maxImageEdge: CGFloat = 1600
    /// 缩略图长边上限。列表只显示小图，缓存原图会让长会话迅速吃光内存。
    private static let thumbnailEdge: CGFloat = 320
    private static let jpegQuality: CGFloat = 0.82

    private let directory: URL
    /// NSCache 会在内存压力下自动回收，比手写 LRU 省事。
    private let thumbnails = NSCache<NSString, UIImage>()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("attachments", isDirectory: true)
        // 目录缺失时写入会直接失败；这里创建失败也不该拦住 App 启动，等真正保存时再报错。
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - 落盘

    func save(data: Data, fileName: String, mimeType: String, kind: AttachmentKind) throws -> AttachmentRef {
        guard data.count <= Self.maxByteCount else { throw AttachmentError.tooLarge }

        switch kind {
        case .image:
            // 按内容判断是不是图片，不看扩展名：相册导出的名字经常和真实格式对不上。
            guard let image = UIImage(data: data) else { throw AttachmentError.notAnImage }
            let resized = Self.scaled(image, maxEdge: Self.maxImageEdge)
            guard let jpeg = resized.jpegData(compressionQuality: Self.jpegQuality) else {
                throw AttachmentError.writeFailed("图片编码失败。")
            }
            let id = UUID()
            let storedName = "\(id.uuidString).jpg"
            try write(jpeg, storedName: storedName)
            return AttachmentRef(
                id: id,
                kind: .image,
                fileName: fileName,
                mimeType: "image/jpeg",
                byteCount: jpeg.count,
                storedName: storedName
            )
        case .file:
            // 普通文件不解析内容，zip、pdf 原样写入；扩展名只用来保留打开方式。
            let id = UUID()
            let ext = Self.fileExtension(fileName)
            let storedName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
            try write(data, storedName: storedName)
            return AttachmentRef(
                id: id,
                kind: .file,
                fileName: fileName,
                mimeType: mimeType,
                byteCount: data.count,
                storedName: storedName
            )
        }
    }

    // MARK: - 读取

    func url(for ref: AttachmentRef) -> URL {
        directory.appendingPathComponent(ref.storedName)
    }

    func image(for ref: AttachmentRef) -> UIImage? {
        guard ref.kind == .image else { return nil }
        let key = ref.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        // 原图只在生成缩略图时短暂存在，不进缓存，否则缓存就不叫缩略图了。
        guard let full = UIImage(contentsOfFile: url(for: ref).path) else { return nil }
        let thumb = Self.scaled(full, maxEdge: Self.thumbnailEdge)
        thumbnails.setObject(thumb, forKey: key)
        return thumb
    }

    func base64(for ref: AttachmentRef) -> String? {
        // 用户可能在系统「文件」里删掉附件，读不到返回 nil，让调用方按「附件已丢」处理。
        guard let data = try? Data(contentsOf: url(for: ref)) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - 删除与统计

    func delete(_ ref: AttachmentRef) {
        thumbnails.removeObject(forKey: ref.id.uuidString as NSString)
        // 文件本来就不在时也算删除完成，调用方不需要知道磁盘上的真实情况。
        try? FileManager.default.removeItem(at: url(for: ref))
    }

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        )) ?? []
        var total = 0
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += size
        }
        return total
    }

    func clearAll() {
        thumbnails.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        // 只删文件、保留目录，下一次保存不必再考虑目录是否存在。
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 私有

    private func write(_ data: Data, storedName: String) throws {
        do {
            try data.write(to: directory.appendingPathComponent(storedName), options: .atomic)
        } catch {
            throw AttachmentError.writeFailed(error.localizedDescription)
        }
    }

    /// 按长边等比缩到上限内。用像素而不是 point 计算，否则 2x 图会缩成目标的两倍大。
    private static func scaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxEdge else { return image }
        let ratio = maxEdge / longest
        let target = CGSize(
            width: (pixelWidth * ratio).rounded(),
            height: (pixelHeight * ratio).rounded()
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func fileExtension(_ fileName: String) -> String {
        let name = (fileName as NSString).lastPathComponent
        return (name as NSString).pathExtension.lowercased()
    }
}
