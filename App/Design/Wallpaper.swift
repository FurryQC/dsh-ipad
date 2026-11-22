import SwiftUI
import UIKit
import PhotosUI
import ImageIO

/// 壁纸的显示参数。跟设备走，存 UserDefaults。
struct WallpaperSettings: Codable, Equatable {
    /// 模糊半径 0...24。默认 6：还看得出是张照片，又不和上面的文字抢注意力。
    var blur: Double = 6
    /// 暗化遮罩 0...0.8。默认 0.35，白字压上去也读得清。
    var dim: Double = 0.35
    /// 有没有可用的壁纸文件。图片可能因为文件被删掉而暂时为空，以这个标记为准。
    var hasImage: Bool = false
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

/// 自定义壁纸的唯一入口。图片存沙盒，设置存 UserDefaults；视图通过 @ObservedObject 跟着刷新。
@MainActor
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()

    /// 设置一改就落盘（滑杆拖动时也一样），所以外面不用关心"什么时候该保存"。
    @Published var settings = WallpaperSettings() {
        didSet { persistSettings() }
    }

    /// 已经解码好的壁纸图。缓存一份，免得每次重绘都从磁盘读 JPEG。
    @Published var image: UIImage? = nil

    /// 设置键。这点数据不值得单开一个文件。
    private static let settingsKey = "dsh.wallpaper.settings"

    /// 壁纸留在 Documents 根目录，不进 workspace：那是模型用工具能读写的地方。
    var imageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper.jpg")
    }

    init() {
        // 自己先读一次：调用方漏了 load() 也不会显示成没壁纸。重复调用无副作用。
        load()
    }

    /// 启动时调用：读回设置和图片。图片文件不在了就把 hasImage 降回 false，免得背景一直空着。
    func load() {
        if let data = UserDefaults.standard.data(forKey: WallpaperStore.settingsKey),
           let stored = try? JSONDecoder().decode(WallpaperSettings.self, from: data) {
            settings = stored
        }

        if settings.hasImage,
           let data = try? Data(contentsOf: imageURL),
           let loaded = UIImage(data: data) {
            image = loaded
            return
        }

        image = nil
        if settings.hasImage {
            settings.hasImage = false
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
        image = UIImage(data: jpeg)
        settings.hasImage = true
    }

    /// 清除壁纸：删文件、关标记。文件本来就不在也当成功。
    func clear() {
        try? FileManager.default.removeItem(at: imageURL)
        image = nil
        settings.hasImage = false
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

/// 全局背景层。有壁纸就铺满 + 模糊 + 压暗，没有就用 Theme 的暗色渐变（边上带一点强调色辉光）。
/// 只有背景忽略安全区，内容照常参与布局。
struct WallpaperBackground<Content: View>: View {
    @ObservedObject private var store = WallpaperStore.shared

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
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
        if store.settings.hasImage, let image = store.image {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    // 放大一点点再裁：模糊后四边不会渗出一道浅色描边。
                    .scaleEffect(1.06)
                    .clipped()
            }
            .blur(radius: CGFloat(store.settings.blur))
            .overlay(Color.black.opacity(store.settings.dim))
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

/// 壁纸设置页。自带 NavigationView，以 sheet 弹出；选图、调参数、清除都在这一页。
struct WallpaperPickerView: View {
    @ObservedObject var store: WallpaperStore

    @Environment(\.dismiss) private var dismiss
    @State private var pickedItem: PhotosPickerItem?
    @State private var isLoading = false
    @State private var errorText: String?

    init(store: WallpaperStore = WallpaperStore.shared) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        NavigationView {
            Form {
                previewSection
                imageSection
                adjustSection
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
                if let image = store.image {
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(1.06)
                            .clipped()
                    }
                    .blur(radius: CGFloat(store.settings.blur))
                    .overlay(Color.black.opacity(store.settings.dim))
                    .overlay(alignment: .bottomLeading) {
                        Text("示例文字")
                            .font(Theme.title(15))
                            .foregroundColor(Theme.textPrimary)
                            .padding(10)
                    }
                } else {
                    Theme.bgGradient
                    Text("还没有自定义壁纸，现在用的是暗色底。")
                        .font(Theme.body(13))
                        .foregroundColor(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Theme.surface)
        }
    }

    private var imageSection: some View {
        Section {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundColor(Theme.accent)
                    Text(store.settings.hasImage ? "换一张照片" : "从照片里选一张")
                        .foregroundColor(Theme.textPrimary)
                    Spacer(minLength: 0)
                    if isLoading {
                        ProgressView()
                    }
                }
            }
            .listRowBackground(Theme.surface)

            if store.settings.hasImage {
                Button(role: .destructive) {
                    store.clear()
                } label: {
                    Text("清除自定义壁纸")
                }
                .listRowBackground(Theme.surface)
            }
        } header: {
            Text("图片")
        } footer: {
            Text("壁纸只存在这台设备上，不会上传；工作目录里的文件不受影响。")
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
        } header: {
            Text("显示")
        } footer: {
            Text("模糊和暗化都是为了让壁纸上的正文读得清；拉到 0 就是原图。")
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
                .frame(width: 44, alignment: .trailing)
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - 选图

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
}
