import SwiftUI
import WebKit

/// HTML 壁纸：用户导入的 .html 放进一个不可交互的 WKWebView 里跑。
/// 这样壁纸可以是 CSS 动画、canvas 粒子、时钟之类，代价是常驻一个 web 进程。
/// 指针穿透（isUserInteractionEnabled = false），壁纸不能抢聊天界面的手势。
struct HTMLWallpaperView: UIViewRepresentable {
    let fileURL: URL?
    /// 导入新文件后要强制重载：只比 URL 不会变，得靠这个计数把旧的页面顶掉。
    let reloadToken: Int

    /// 导入的网页不一定自己撑满：html/body 有默认 margin，body 有默认宽度，
    /// 结果就是左上角一小块在跑动画、其余是空底。这里把页面钉死成整屏画布。
    private static let fullScreenCSS = "html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}body>*{max-width:100%;}"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 脚本挂在 configuration 上：WebView 建好之后再挂，对当前页面不生效（要重载一次），
        // 所以必须在 init 之前挂好。
        config.userContentController.addUserScript(
            WKUserScript(source: HTMLWallpaperView.fullScreenCSS,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.backgroundColor = .clear
        // 不关这个，安全区会自动加 content inset，铺满屏幕的壁纸上下会各留一条底。
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.contentInset = .zero
        web.isUserInteractionEnabled = false
        web.allowsBackForwardNavigationGestures = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard let fileURL = fileURL else { return }
        let key = "\(fileURL.path)#\(reloadToken)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        web.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedKey: String?
    }
}

/// 网页壁纸层：垫黑底 → 网页 → 毛玻璃（替 SwiftUI 的 .blur，它糊不动 WKWebView）→ 压暗。
/// 全局背景和设置页预览共用，免得两处各写一遍、调完模糊预览和实际效果对不上。
struct HTMLWallpaperLayer: View {
    let url: URL?
    let reloadToken: Int
    let blur: Double
    let dim: Double

    var body: some View {
        ZStack {
            // WebView 是透明底的，垫一层黑：网页没铺满时不会漏出系统背景。
            Color.black
            if let url = url {
                HTMLWallpaperView(fileURL: url, reloadToken: reloadToken)
            }
            if blur > 0.5 {
                VideoBlurVeil(intensity: blur / 24)
                    .allowsHitTesting(false)
            }
            Color.black
                .opacity(dim)
                .allowsHitTesting(false)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}
