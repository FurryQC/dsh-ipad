import SwiftUI
import WebKit

/// HTML 壁纸：用户导入的 .html 放进一个不可交互的 WKWebView 里跑。
/// 这样壁纸可以是 CSS 动画、canvas 粒子、时钟之类，代价是常驻一个 web 进程。
/// 指针穿透（isUserInteractionEnabled = false），壁纸不能抢聊天界面的手势。
struct HTMLWallpaperView: UIViewRepresentable {
    let fileURL: URL?
    /// 导入新文件后要强制重载：只比 URL 不会变，得靠这个计数把旧的页面顶掉。
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.backgroundColor = .clear
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
