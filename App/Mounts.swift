import Foundation

/// 用户手动授权的外部文件夹。
///
/// iOS 上拿到 App 沙盒之外读写权的唯一办法：在系统「文件」里选一个目录，
/// 把这个目录的 security-scoped bookmark 存下来；之后每次访问前
/// `startAccessingSecurityScopedResource()`，App 重启后仍然有效。
struct MountedFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data
}

/// 已授权文件夹的登记表。工具里用 `mount:<名字>/子路径` 访问。
final class MountStore {
    static let shared = MountStore()

    private static let defaultsKey = "dsh.mounts"
    private var storage: [MountedFolder] = []
    /// 已经 startAccessing 过的目录，避免重复计数、也避免反复问系统。
    private var started: Set<String> = []

    private init() {
        load()
    }

    var mounts: [MountedFolder] { storage }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: MountStore.defaultsKey),
              let list = try? JSONDecoder().decode([MountedFolder].self, from: data) else {
            storage = []
            return
        }
        storage = list
        for mount in list {
            _ = baseURL(for: mount)
        }
    }

    /// 授权一个新目录。名字取目录名，重名就加序号，模型不用关心重复。
    @discardableResult
    func add(url: URL) throws -> MountedFolder {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        } catch {
            throw ToolFailure.message("这个文件夹没法持久授权：\(error.localizedDescription)。换一个目录试试。")
        }

        var name = url.lastPathComponent
        if name.isEmpty { name = "文件夹" }
        var candidate = name
        var index = 2
        while storage.contains(where: { $0.name == candidate }) {
            candidate = "\(name)\(index)"
            index += 1
        }

        let mount = MountedFolder(id: UUID(), name: candidate, bookmark: bookmark)
        storage.append(mount)
        persist()
        _ = baseURL(for: mount)
        return mount
    }

    func remove(id: UUID) {
        storage.removeAll { $0.id == id }
        persist()
    }

    /// 按名字找挂载根目录。找不到就是名字写错了，把可用名字列出来。
    func resolve(name: String) throws -> URL {
        guard let mount = storage.first(where: { $0.name == name }) else {
            let names = storage.map { $0.name }.joined(separator: ", ")
            let hint = names.isEmpty ? "还没有授权任何外部文件夹。" : "可用的是：\(names)"
            throw ToolFailure.message("没有名为 \(name) 的挂载目录。\(hint)")
        }
        guard let url = baseURL(for: mount) else {
            throw ToolFailure.message("挂载目录 \(name) 失效了（可能被移动或删除），去设置里重新加一次。")
        }
        return url
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: MountStore.defaultsKey)
    }

    /// 解 bookmarks 并保持访问权限。返回 nil 表示书签已失效。
    private func baseURL(for mount: MountedFolder) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: mount.bookmark,
                                 options: [],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return nil
        }
        let key = url.standardizedFileURL.path
        if !started.contains(key) {
            if url.startAccessingSecurityScopedResource() {
                started.insert(key)
            }
        }
        if stale, let refreshed = try? url.bookmarkData(options: [],
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
            if let index = storage.firstIndex(where: { $0.id == mount.id }) {
                storage[index].bookmark = refreshed
                persist()
            }
        }
        return url
    }
}
