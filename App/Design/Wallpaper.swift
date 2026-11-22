import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import Foundation

/// 壁纸的显示参数。跟设备走，存 UserDefaults。
struct WallpaperSettings: Codable, Equatable {
    /// 模糊半径 0...24。默认 6：还看得出是张照片，又不和上面的文字抢注意力。
    var blur: Double = 6
    /// 暗化遮罩 0...0.8。默认 0.35，白字压上去也读得清。
    var dim: Double = 0.35
    /// 有没有可用的壁纸（照片或视频）。文件可能被删掉而暂时为空，以这个标记为准。
    var hasImage: Bool = false
    /// 壁纸是不是视频。hasImage 为 true 时它决定用视频还是照片。
    var hasVideo: Bool = false
    /// 画面缩放 1...3。1 是铺满并裁切后的原始状态。
    var scale: Double = 1
    /// 横向位移，按屏宽的一半归一化，-1...1。
    var offsetX: Double = 0
    /// 纵向位移，按屏高的一半归一化，-1...1。
    var offsetY: Double = 0
    /// 视频循环起点（秒）。导入后按实际时长夹到 0...10。
    var startSecond: Double = 0
    /// 壁纸是不是网页。为 true 时用 WebView 跑 Documents/wallpaper.html，照片和视频都不生效。
    var hasHTML: Bool = false
    /// 用过的壁纸，最新的在前，最多 8 条。文件在 Documents/wallpapers/ 下。
    var history: [WallpaperHistoryItem] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case blur
        case dim
        case hasImage
        case hasVideo
        case scale
        case offsetX
        case offsetY
        case startSecond
        case hasHTML
        case history
    }

    /// 旧版本只存了 blur / dim / hasImage。缺的字段补默认值，升级后壁纸不能凭空消失。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 6
        dim = try container.decodeIfPresent(Double.self, forKey: .dim) ?? 0.35
        hasImage = try container.decodeIfPresent(Bool.self, forKey: .hasImage) ?? false
        hasVideo = try container.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        startSecond = try container.decodeIfPresent(Double.self, forKey: .startSecond) ?? 0
        hasHTML = try container.decodeIfPresent(Bool.self, forKey: .hasHTML) ?? false
        history = try container.decodeIfPresent([WallpaperHistoryItem].self, forKey: .history) ?? []
    }
}

/// 一条壁纸历史。只是个索引：真正的文件在 Documents/wallpapers/<fileName>。
struct WallpaperHistoryItem: Codable, Identifiable, Equatable {
    /// 主键。跟 fileName 里的 UUID 不是同一个，改文件名不会影响条目标识。
    var id: UUID
    /// "image" / "video" / "html"。存字符串而不是枚举：以后加种类不用动存档格式。
    var kind: String
    /// wallpapers/ 下的文件名，例如 <uuid>.jpg。
    var fileName: String
    var createdAt: Date
}

/// 壁纸读写的失败原因。直接把它显示给用户，不把底层错误文本端上去。
enum WallpaperError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 自定义壁纸的唯一入口。照片/视频存沙盒，设置存 UserDefaults；视图通过 @ObservedObject 跟着刷新。
@MainActor
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()

    /// 设置一改就落盘（滑杆拖动时也一样），所以外面不用关心"什么时候该保存"。
    @Published var settings = WallpaperSettings() {
        didSet { persistSettings() }
    }

    /// 已经解码好的壁纸图。缓存一份，免得每次重绘都从磁盘读 JPEG。视频壁纸时为空。
    @Published var image: UIImage? = nil

    /// 视频总时长（秒）。导入或读回视频后异步量一次，设置页用它限制起点滑杆。
    @Published var videoDuration: Double = 0

    /// 设置键。这点数据不值得单开一个文件。
    private static let settingsKey = "dsh.wallpaper.settings"

    /// 壁纸留在 Documents 根目录，不进 workspace：那是模型用工具能读写的地方。
    var imageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper.jpg")
    }

    /// 视频壁纸固定文件名。导入时不转码：AVPlayer 按内容识别 mov / mp4，扩展名只求稳定。
    var videoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper.mov")
    }

    /// 实际能播放的视频地址。标记为视频但文件没了就返回 nil，背景会退回底图。
    var videoURLForPlayback: URL? {
        guard settings.hasVideo else { return nil }
        return FileManager.default.fileExists(atPath: videoURL.path) ? videoURL : nil
    }

    /// 网页壁纸固定文件名。同目录的图片/字体能相对引用（allowingReadAccessTo 给了整个 Documents）。
    var htmlURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper.html")
    }

    /// 网页壁纸要加载的地址。标记为网页但文件没了就返回 nil。
    var htmlURLForDisplay: URL? {
        guard settings.hasHTML else { return nil }
        return FileManager.default.fileExists(atPath: htmlURL.path) ? htmlURL : nil
    }

    /// 三种壁纸里有没有任意一种。网页壁纸不算 hasImage，预览和"清除"入口要看这个。
    var hasWallpaper: Bool {
        settings.hasHTML || settings.hasImage
    }

    /// 壁纸历史文件目录。用到的时候才建，空目录没必要提前造。
    var wallpapersDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpapers", isDirectory: true)
    }

    /// 历史缩略图缓存。历史一变就整批重读：8 张 160px 的图，开销可以忽略。
    /// 直接渲染时从磁盘读 2048px 的原图会把 Form 拖慢。
    @Published private(set) var historyThumbs: [UUID: UIImage] = [:]

    /// 换了一个 html 文件后 WebView 得重新加载：路径不变，靠这个计数触发刷新。
    @Published private(set) var htmlReloadToken = 0

    /// 起点滑杆的上限：最多 10 秒，也绝不越过结尾。
    var maxStartSecond: Double {
        guard videoDuration > 0.2 else { return 10 }
        return min(10, max(0, videoDuration - 0.2))
    }

    init() {
        // 自己先读一次：调用方漏了 load() 也不会显示成没壁纸。重复调用无副作用。
        load()
    }

    /// 启动时调用：读回设置和文件。文件不在了就把标记降回 false，免得背景一直空着。
    func load() {
        if let data = UserDefaults.standard.data(forKey: WallpaperStore.settingsKey),
           let stored = try? JSONDecoder().decode(WallpaperSettings.self, from: data) {
            settings = stored
        }
        applyActualWallpaperState()
        refreshHistoryThumbs()
    }

    /// 按磁盘上真实存在的文件把三个互斥标记对齐，优先级：网页 > 视频 > 照片。
    /// 文件被删掉、或者旧版本存下半开状态（比如 hasHTML 和 hasImage 同时为真）时，这里收干净。
    private func applyActualWallpaperState() {
        if settings.hasHTML, FileManager.default.fileExists(atPath: htmlURL.path) {
            image = nil
            videoDuration = 0
            if settings.hasImage {
                settings.hasImage = false
            }
            if settings.hasVideo {
                settings.hasVideo = false
            }
            return
        }

        if settings.hasVideo, FileManager.default.fileExists(atPath: videoURL.path) {
            image = nil
            if !settings.hasImage {
                settings.hasImage = true
            }
            if settings.hasHTML {
                settings.hasHTML = false
            }
            refreshVideoDuration()
            return
        }

        if settings.hasImage,
           let data = try? Data(contentsOf: imageURL),
           let loaded = UIImage(data: data) {
            image = loaded
            videoDuration = 0
            if settings.hasVideo {
                settings.hasVideo = false
            }
            if settings.hasHTML {
                settings.hasHTML = false
            }
            return
        }

        image = nil
        videoDuration = 0
        if settings.hasImage {
            settings.hasImage = false
        }
        if settings.hasVideo {
            settings.hasVideo = false
        }
        if settings.hasHTML {
            settings.hasHTML = false
        }
    }

    /// 导入一张照片：按 EXIF 转正方向、长边压到 2048、重编码成 JPEG 0.9。
    /// 原图可能是 HEIC 或带旋转信息，统一转一遍壁纸显示才不会歪、也不会占几十 MB。
    func importImage(data: Data) throws {
        guard let jpeg = WallpaperStore.makeWallpaperData(from: data) else {
            throw WallpaperError.message("这张图读不出来，换一张（JPG / PNG / HEIC 都可以）。")
        }
        do {
            try jpeg.write(to: imageURL, options: .atomic)
        } catch {
            throw WallpaperError.message("壁纸写不进沙盒：\(error.localizedDescription)")
        }
        // 三种壁纸互斥：换照片就把视频和网页一起作废，背景只看一个标记决定画什么。
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: htmlURL)
        image = UIImage(data: jpeg)
        videoDuration = 0
        settings.hasVideo = false
        settings.hasHTML = false
        settings.hasImage = true
        recordHistory(kind: "image", data: jpeg, preferredExtension: "jpg")
    }

    /// 导入一段视频：原文件拷进 Documents（不转码），照片壁纸一并清掉。
    func importVideo(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }

        let destination = videoURL
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw WallpaperError.message("这段视频拷不进沙盒：\(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: htmlURL)
        image = nil
        videoDuration = 0
        settings.hasVideo = true
        settings.hasImage = true
        settings.hasHTML = false
        settings.startSecond = min(settings.startSecond, 10)
        refreshVideoDuration()
        recordHistory(kind: "video", copying: destination, preferredExtension: "mov")
    }

    /// 导入网页壁纸：拷成 Documents/wallpaper.html，照片和视频一并清掉。
    func importHTML(from source: URL) throws {
        let ext = source.pathExtension.lowercased()
        guard ext == "html" || ext == "htm" else {
            throw WallpaperError.message("只支持 .html / .htm 文件。想做动画壁纸，把 HTML 和它的图片、CSS 放同一个文件夹里再一起导入（现在只取这一个文件）。")
        }

        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: source) else {
            throw WallpaperError.message("这个 html 读不出来：文件可能已经不在原来的位置了。")
        }
        do {
            try data.write(to: htmlURL, options: .atomic)
        } catch {
            throw WallpaperError.message("这个 html 拷不进沙盒：\(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: videoURL)
        image = nil
        videoDuration = 0
        settings.hasVideo = false
        settings.hasImage = false
        settings.hasHTML = true
        htmlReloadToken += 1
        recordHistory(kind: "html", data: data, preferredExtension: "html")
    }

    /// 清除壁纸：删照片和视频、关标记、画面参数回到原始状态。文件本来就不在也当成功。
    func clear() {
        try? FileManager.default.removeItem(at: imageURL)
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: htmlURL)
        image = nil
        videoDuration = 0
        settings.hasImage = false
        settings.hasVideo = false
        settings.hasHTML = false
        settings.scale = 1
        settings.offsetX = 0
        settings.offsetY = 0
        settings.startSecond = 0
    }

    /// 应用一条历史：把它的文件复制成当前的 wallpaper.*，并按种类把三个标记对齐。
    /// 文件被外面删了就把那一条从历史里摘掉，别让用户点了没反应。
    func applyHistory(_ item: WallpaperHistoryItem) {
        let source = historyFileURL(item.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            settings.history.removeAll { $0.id == item.id }
            refreshHistoryThumbs()
            return
        }

        switch item.kind {
        case "video":
            do {
                try? FileManager.default.removeItem(at: videoURL)
                try FileManager.default.copyItem(at: source, to: videoURL)
            } catch {
                return
            }
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: htmlURL)
            image = nil
            settings.hasVideo = true
            settings.hasImage = true
            settings.hasHTML = false
            refreshVideoDuration()
        case "html":
            guard let data = try? Data(contentsOf: source) else { return }
            do {
                try data.write(to: htmlURL, options: .atomic)
            } catch {
                return
            }
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
            image = nil
            videoDuration = 0
            settings.hasVideo = false
            settings.hasImage = false
            settings.hasHTML = true
            htmlReloadToken += 1
        default:
            do {
                try? FileManager.default.removeItem(at: imageURL)
                try FileManager.default.copyItem(at: source, to: imageURL)
            } catch {
                return
            }
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: htmlURL)
            if let data = try? Data(contentsOf: imageURL) {
                image = UIImage(data: data)
            } else {
                image = nil
            }
            videoDuration = 0
            settings.hasVideo = false
            settings.hasHTML = false
            settings.hasImage = true
        }
    }

    /// 清空历史：条目和 wallpapers/ 里的文件一起删。当前壁纸不动。
    func clearHistory() {
        settings.history = []
        historyThumbs = [:]
        try? FileManager.default.removeItem(at: wallpapersDirectory)
    }

    // MARK: - 历史文件

    /// 把一份数据存进 wallpapers/ 并记进历史。写失败就当没记，不能影响刚导入成功的壁纸。
    private func recordHistory(kind: String, data: Data, preferredExtension ext: String) {
        let fileName = "\(UUID().uuidString).\(ext)"
        let url = historyFileURL(fileName)
        do {
            try ensureWallpapersDirectory()
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        appendHistory(kind: kind, fileName: fileName)
    }

    /// 同上，但源文件已经在磁盘上（视频），直接再复制一份。
    private func recordHistory(kind: String, copying source: URL, preferredExtension ext: String) {
        let fileName = "\(UUID().uuidString).\(ext)"
        let url = historyFileURL(fileName)
        do {
            try ensureWallpapersDirectory()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            return
        }
        appendHistory(kind: kind, fileName: fileName)
    }

    private func ensureWallpapersDirectory() throws {
        try FileManager.default.createDirectory(at: wallpapersDirectory,
                                                withIntermediateDirectories: true)
    }

    private func historyFileURL(_ fileName: String) -> URL {
        wallpapersDirectory.appendingPathComponent(fileName)
    }

    private func appendHistory(kind: String, fileName: String) {
        let item = WallpaperHistoryItem(id: UUID(), kind: kind, fileName: fileName, createdAt: Date())
        settings.history.insert(item, at: 0)
        trimHistory()
        refreshHistoryThumbs()
    }

    /// 只留最近 8 条：超出的是最久没用过的，连文件一起删，不然两个视频就能吃掉几百 MB。
    private func trimHistory() {
        while settings.history.count > 8 {
            let dropped = settings.history.removeLast()
            try? FileManager.default.removeItem(at: historyFileURL(dropped.fileName))
        }
    }

    /// 重读所有缩略图。最多 8 张 160px，同步解码也就几毫秒一张，不值得为它开线程。
    private func refreshHistoryThumbs() {
        var thumbs: [UUID: UIImage] = [:]
        for item in settings.history where item.kind != "html" {
            if let thumb = WallpaperStore.historyThumbnail(at: historyFileURL(item.fileName)) {
                thumbs[item.id] = thumb
            }
        }
        historyThumbs = thumbs
    }

    /// 历史格子的缩略图：160px 够 60×60 用，不用把整张 2048px 的壁纸读进内存。
    private static func historyThumbnail(at url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 160
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// 调模糊。夹在 0...24 内：再大壁纸就糊成一块色斑，没有"壁纸"的意义了。
    func setBlur(_ v: Double) {
        settings.blur = min(24, max(0, v))
    }

    /// 调暗化。夹在 0...0.8 内：全黑就等于把壁纸关了。
    func setDim(_ v: Double) {
        settings.dim = min(0.8, max(0, v))
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: WallpaperStore.settingsKey)
    }

    /// 视频时长是异步读的；读到之前起点滑杆按 0...10 给，读到之后收紧。
    private func refreshVideoDuration() {
        guard settings.hasVideo else {
            videoDuration = 0
            return
        }
        let url = videoURL
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            self.videoDuration = seconds
            let limit = self.maxStartSecond
            if self.settings.startSecond > limit {
                self.settings.startSecond = limit
            }
        }
    }

    /// ImageIO 缩图会顺手按 EXIF 把方向转正，比手绘 UIGraphics 省内存也不容易转错。
    private static func makeWallpaperData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceCreateThumbnailWithTransform as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 2048
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage, scale: 1, orientation: .up).jpegData(compressionQuality: 0.9)
        }
        return UIImage(data: data)?.jpegData(compressionQuality: 0.9)
    }
}

/// 壁纸内容层：照片或视频 + 缩放/位移 + 模糊/暗化。全局背景和设置页预览共用，
/// 免得两处的变换逻辑各写一遍、调完滑杆预览和实际效果对不上。
struct WallpaperSurface: View {
    let image: UIImage?
    let videoURL: URL?
    let settings: WallpaperSettings

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ZStack {
                    if let videoURL = videoURL {
                        VideoWallpaperView(url: videoURL, startSecond: settings.startSecond)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else if let image = image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        Theme.bgGradient
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(CGFloat(settings.scale))
                .offset(x: CGFloat(settings.offsetX) * proxy.size.width * 0.5,
                        y: CGFloat(settings.offsetY) * proxy.size.height * 0.5)

                // 视频层是独立合成的，SwiftUI 的 .blur 对 AVPlayerLayer 内容通常不起作用；
                // 用毛玻璃盖一层，模糊滑杆对视频也真的看得出效果。
                if videoURL != nil && settings.blur > 0.5 {
                    VideoBlurVeil(intensity: settings.blur / 24)
                        .allowsHitTesting(false)
                }

                Color.black
                    .opacity(settings.dim)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .blur(radius: videoURL == nil ? CGFloat(settings.blur) : 0)
    }
}

/// 全局背景层。有壁纸就铺满 + 模糊 + 压暗，没有就用 Theme 的暗色渐变（边上带一点强调色辉光）。
/// 只有背景忽略安全区，内容照常参与布局。
struct WallpaperBackground<Content: View>: View {
    @ObservedObject private var store: WallpaperStore

    private let content: Content

    init(store: WallpaperStore = WallpaperStore.shared, @ViewBuilder content: () -> Content) {
        _store = ObservedObject(wrappedValue: store)
        self.content = content()
    }

    var body: some View {
        ZStack {
            // 垫一层纯色：模糊会把边缘往透明里推，底下不能漏出系统背景色。
            Theme.bg
                .ignoresSafeArea()
            wallpaper
                .ignoresSafeArea()
            content
        }
    }

    @ViewBuilder
    private var wallpaper: some View {
        if store.settings.hasHTML {
            HTMLWallpaperLayer(url: store.htmlURLForDisplay,
                               reloadToken: store.htmlReloadToken,
                               blur: store.settings.blur,
                               dim: store.settings.dim)
                // 网页自己撑不满时也不能溢出到内容层之外。
                .clipped()
        } else if store.settings.hasImage {
            WallpaperSurface(image: store.image,
                             videoURL: store.videoURLForPlayback,
                             settings: store.settings)
                // 多放大一点点再裁：模糊后四边不会渗出一道浅色描边。
                .scaleEffect(1.04)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Theme.bgGradient
                // 极淡的辉光，只给近黑底一点纵深；亮度不到能看清的程度，不算"花哨渐变"。
                RadialGradient(
                    colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0.0)],
                    center: .top,
                    startRadius: 0,
                    endRadius: 620
                )
            }
        }
    }
}

/// 壁纸设置页。自带 NavigationView，以 sheet 弹出；选照片/视频、调画面、清除都在这一页。
struct WallpaperPickerView: View {
    @ObservedObject var store: WallpaperStore

    /// 用户在"自定义壁纸"里写了描述、点了「让 AI 写一个」时回调出去。
    /// 这一页不自己起对话：起对话、拼提示词是调用方的事。
    private let onCustomPrompt: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedVideoItem: PhotosPickerItem?
    @State private var showVideoImporter = false
    @State private var showHTMLImporter = false
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var customPrompt = ""

    init(store: WallpaperStore = WallpaperStore.shared,
         onCustomPrompt: ((String) -> Void)? = nil) {
        _store = ObservedObject(wrappedValue: store)
        self.onCustomPrompt = onCustomPrompt
    }

    var body: some View {
        NavigationView {
            Form {
                previewSection
                historySection
                imageSection
                videoSection
                htmlSection
                adjustSection
                customSection
                clearSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgGradient.ignoresSafeArea())
            .navigationTitle("壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(Theme.accent)
                }
            }
            .onChange(of: pickedItem) { item in
                guard let item = item else { return }
                load(item)
            }
            .onChange(of: pickedVideoItem) { item in
                guard let item = item else { return }
                loadVideo(item)
            }
            .fileImporter(isPresented: $showVideoImporter,
                          allowedContentTypes: [.movie],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    importVideoFile(url)
                case .failure:
                    // 用户取消也会走 failure，这里不当成错误弹窗。
                    break
                }
            }
            .sheet(isPresented: $showHTMLImporter) {
                DocumentPicker(mode: .files) { urls in
                    showHTMLImporter = false
                    guard let url = urls.first else { return }
                    do {
                        try store.importHTML(from: url)
                    } catch {
                        errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                .ignoresSafeArea()
            }
            .alert("壁纸没设上", isPresented: Binding(
                get: { errorText != nil },
                set: { newValue in if !newValue { errorText = nil } }
            )) {
                Button("知道了", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        // iPad 常规宽度下 NavigationView 会自作主张分栏，设置页只剩一个空导航栏；强制单列。
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }

    // MARK: - 各段

    /// 实时预览。不在这一页放预览的话，滑杆调了半天要关掉页面才看得到效果。
    private var previewSection: some View {
        Section {
            ZStack {
                if store.settings.hasHTML {
                    HTMLWallpaperLayer(url: store.htmlURLForDisplay,
                                       reloadToken: store.htmlReloadToken,
                                       blur: store.settings.blur,
                                       dim: store.settings.dim)
                } else if store.settings.hasImage {
                    WallpaperSurface(image: store.image,
                                     videoURL: store.videoURLForPlayback,
                                     settings: store.settings)
                } else {
                    Theme.bgGradient
                    Text("还没有自定义壁纸，现在用的是暗色底。")
                        .font(Theme.body(13))
                        .foregroundColor(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // 示例文字：壁纸再花，正文也得读得清，预览里就要能验证这一点。
                if store.hasWallpaper {
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            Text("示例文字")
                                .font(Theme.title(15))
                                .foregroundColor(Theme.textPrimary)
                                .padding(10)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Theme.surface)
        }
    }

    /// 历史：横向 60×60 的格子，点一下直接切过去。网页壁纸没有缩略图，用图标顶着。
    private var historySection: some View {
        Section {
            if store.settings.history.isEmpty {
                Text("还没有历史。导入过的壁纸会留在这里，最多 8 张。")
                    .font(Theme.body(13))
                    .foregroundColor(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.settings.history) { item in
                            Button {
                                store.applyHistory(item)
                            } label: {
                                historyCell(item)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: Theme.pad, bottom: 8, trailing: Theme.pad))
                .listRowBackground(Theme.surface)

                Button(role: .destructive) {
                    store.clearHistory()
                } label: {
                    Text("清空历史")
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("历史")
        } footer: {
            Text("只留最近 8 张。点一下直接换成那张壁纸；清空历史只删记录，不动当前壁纸。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func historyCell(_ item: WallpaperHistoryItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(Theme.surfaceStrong)
            if item.kind == "html" {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.accent)
            } else if let thumb = store.historyThumbs[item.id] {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else if item.kind == "video" {
                Image(systemName: "video")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    /// 自定义壁纸入口：把一句话描述交出去，由调用方开对话让 agent 写 wallpaper.html。
    private var customSection: some View {
        Section {
            TextField("描述你想要的壁纸…", text: $customPrompt)
                .foregroundColor(Theme.textPrimary)
                .listRowBackground(Theme.surface)
            Button {
                submitCustomPrompt()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundColor(Theme.accent)
                    Text("让 AI 写一个")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("自定义壁纸")
        } footer: {
            Text("用一句话描述想要的效果，会新开一个对话让 agent 写 .html 壁纸；写好后再回到这里导入。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var htmlSection: some View {
        Section {
            Button {
                showHTMLImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundColor(Theme.accent)
                    Text(store.settings.hasHTML ? "换一个网页壁纸" : "导入网页壁纸（.html）")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                    }
                }
            }
            .listRowBackground(Theme.surface)

            if store.settings.hasHTML {
                Text("当前是网页壁纸。网页里的动画会一直跑，比较费电；卡就把模糊拉高一点，它会盖一层毛玻璃。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("网页壁纸")
        } footer: {
            Text("选一个 .html 文件，它会在壁纸层里真跑（CSS 动画、canvas 都可以）。目前只取 html 这一个文件：引用了图片或字体的话，请写绝对 URL，或者把资源一起放进 App 的 Documents 目录。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var imageSection: some View {
        Section {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(Theme.accent)
                    Text(store.settings.hasImage && !store.settings.hasVideo && !store.settings.hasHTML
                         ? "换一张照片"
                         : "从照片里选一张")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                    }
                }
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("照片")
        } footer: {
            Text("照片、视频、网页三选一：导入新的会替换当前壁纸，旧的留在历史里可以切回去。壁纸只存在这台设备上，不会上传。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var videoSection: some View {
        Section {
            PhotosPicker(selection: $pickedVideoItem, matching: .videos) {
                HStack(spacing: 10) {
                    Image(systemName: "video.badge.plus")
                        .foregroundColor(Theme.accent)
                    Text(store.settings.hasVideo ? "换一段视频" : "从照片里选视频")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                    }
                }
            }
            .listRowBackground(Theme.surface)

            Button {
                showVideoImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(Theme.accent)
                    Text("从「文件」导入视频")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            .listRowBackground(Theme.surface)

            if store.settings.hasVideo {
                sliderRow(title: "起点",
                          binding: $store.settings.startSecond,
                          range: 0...max(0.5, store.maxStartSecond),
                          valueText: String(format: "%.1fs", store.settings.startSecond))
            }
        } header: {
            Text("视频")
        } footer: {
            Text("视频静音、循环、铺满裁切；切到后台自动暂停，回来继续。起点决定每次循环从哪里开始。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var adjustSection: some View {
        Section {
            sliderRow(title: "模糊",
                      binding: $store.settings.blur,
                      range: 0...24,
                      valueText: "\(Int(store.settings.blur.rounded()))")
            sliderRow(title: "暗化",
                      binding: $store.settings.dim,
                      range: 0...0.8,
                      valueText: "\(Int((store.settings.dim * 100).rounded()))%")
            sliderRow(title: "放大",
                      binding: $store.settings.scale,
                      range: 1...3,
                      valueText: String(format: "%.1f×", store.settings.scale))
            sliderRow(title: "横向",
                      binding: $store.settings.offsetX,
                      range: -1...1,
                      valueText: percentText(store.settings.offsetX))
            sliderRow(title: "纵向",
                      binding: $store.settings.offsetY,
                      range: -1...1,
                      valueText: percentText(store.settings.offsetY))
        } header: {
            Text("画面")
        } footer: {
            Text("模糊和暗化是为了让壁纸上的正文读得清；放大和位移用来挑画面里露出来的部分，预览实时跟着变。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private var clearSection: some View {
        Section {
            if store.hasWallpaper {
                Button(role: .destructive) {
                    store.clear()
                } label: {
                    Text("清除自定义壁纸")
                }
                .listRowBackground(Theme.surface)
            } else {
                Text("当前没有自定义壁纸。")
                    .foregroundColor(Theme.textTertiary)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("重置")
        } footer: {
            Text("清除只删壁纸文件和画面参数；工作目录里的文件不受影响。")
                .foregroundColor(Theme.textTertiary)
        }
    }

    private func sliderRow(title: String, binding: Binding<Double>,
                           range: ClosedRange<Double>, valueText: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundColor(Theme.textPrimary)
                .frame(width: 36, alignment: .leading)
            Slider(value: binding, in: range)
                .tint(Theme.accent)
            Text(valueText)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .listRowBackground(Theme.surface)
    }

    private func percentText(_ value: Double) -> String {
        return String(format: "%+.0f%%", value * 100)
    }

    /// 把描述交给调用方，然后关掉这一页：新对话起来之后这一页也没用了。
    private func submitCustomPrompt() {
        let text = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = "先写一句你想要的壁纸描述。"
            return
        }
        onCustomPrompt?(text)
        dismiss()
    }

    // MARK: - 选照片 / 选视频

    private func load(_ item: PhotosPickerItem) {
        isLoading = true
        Task { @MainActor in
            defer {
                isLoading = false
                pickedItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw WallpaperError.message("读不到这张照片的原始数据，换一张试试。")
                }
                try store.importImage(data: data)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func loadVideo(_ item: PhotosPickerItem) {
        isLoading = true
        Task { @MainActor in
            defer {
                isLoading = false
                pickedVideoItem = nil
            }
            do {
                guard let movie = try await item.loadTransferable(type: WallpaperMovie.self) else {
                    throw WallpaperError.message("读不到这段视频，换一段试试（相册里的 mov / mp4 都可以）。")
                }
                try store.importVideo(from: movie.url)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func importVideoFile(_ url: URL) {
        isLoading = true
        defer { isLoading = false }
        do {
            try store.importVideo(from: url)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
