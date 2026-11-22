import SwiftUI
import UIKit
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// PhotosPicker 取视频用：把选中的影片拷到临时文件，再把 URL 交给壁纸库。
/// 直接从相册拿到的文件可能是加密/托管的，拷一份出来 AVPlayer 才稳定。
struct WallpaperMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("wallpaper-import-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return WallpaperMovie(url: copy)
        }
    }
}

/// 视频壁纸的播放引擎。视图是值类型，播放器必须由引用类型兜住生命周期。
/// 静音、循环、切后台暂停；起点靠 seek 实现，每次循环都从起点重新开始。
final class VideoWallpaperEngine: ObservableObject {
    let player = AVPlayer()

    private var loopToken: NSObjectProtocol?
    private var backgroundToken: NSObjectProtocol?
    private var foregroundToken: NSObjectProtocol?
    private var currentURL: URL?
    private var startSecond: Double = 0
    private var wantsPlayback = false

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        // 播到结尾就拉回起点。自己监听比 AVPlayerLooper 好控制起点：
        // looper 每圈都从 0 开始，startSecond 就只在第一圈生效了。
        loopToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let item = note.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.seekAndPlay()
        }

        backgroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.player.pause()
        }

        foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.wantsPlayback else { return }
            self.player.play()
        }
    }

    deinit {
        if let token = loopToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = backgroundToken {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = foregroundToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 开始播放某个文件。同一个文件重复调用只是重新对齐起点，不重建 item。
    func start(url: URL, startSecond: Double) {
        self.startSecond = max(0, startSecond)
        wantsPlayback = true
        if currentURL != url || player.currentItem == nil {
            currentURL = url
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        seekAndPlay()
    }

    /// 设置页拖起点滑杆：立刻从新位置继续。
    func seek(to second: Double) {
        startSecond = max(0, second)
        seekAndPlay()
    }

    /// 视图消失（切页、sheet 关掉）：停掉解码，不留后台空耗。
    func pause() {
        wantsPlayback = false
        player.pause()
    }

    private func seekAndPlay() {
        guard player.currentItem != nil else { return }
        let target = CMTime(seconds: clampedStart(), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self, self.wantsPlayback else { return }
            self.player.play()
        }
    }

    /// 起点不能越过结尾：越了会 seek 到最后一帧，然后卡在不动的画面上。
    private func clampedStart() -> Double {
        let seconds = player.currentItem?.duration.seconds ?? 0
        guard seconds.isFinite, seconds > 0.3 else { return startSecond }
        return min(startSecond, max(0, seconds - 0.2))
    }
}

/// AVPlayerLayer 的 SwiftUI 包装。直接接管 layerClass，尺寸变化时 playerLayer 自己跟着 bounds 走。
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = .resizeAspectFill
    }
}

/// 只承载 AVPlayerLayer 的 UIView：把 layerClass 换掉，省得管子 layer 的 frame 同步。
final class PlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
}

/// 视频壁纸。任何会变的东西（url / 起点）都用 onChange 转给引擎，视图本身保持无状态。
struct VideoWallpaperView: View {
    let url: URL
    let startSecond: Double

    @StateObject private var engine = VideoWallpaperEngine()

    var body: some View {
        PlayerLayerView(player: engine.player)
            .onAppear {
                engine.start(url: url, startSecond: startSecond)
            }
            .onDisappear {
                engine.pause()
            }
            .onChange(of: url) { newURL in
                engine.start(url: newURL, startSecond: startSecond)
            }
            .onChange(of: startSecond) { newValue in
                engine.seek(to: newValue)
            }
    }
}

/// 视频壁纸的模糊层。AVPlayerLayer 的内容不吃 SwiftUI 的 .blur，
/// 用毛玻璃盖一层才能让模糊滑杆对视频真的看得见效果；档位由小到大近似连续。
struct VideoBlurVeil: UIViewRepresentable {
    let intensity: Double

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: VideoBlurVeil.style(for: intensity)))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: VideoBlurVeil.style(for: intensity))
    }

    private static func style(for intensity: Double) -> UIBlurEffect.Style {
        if intensity < 0.25 {
            return .systemThinMaterialDark
        }
        if intensity < 0.55 {
            return .systemMaterialDark
        }
        if intensity < 0.8 {
            return .systemThickMaterialDark
        }
        return .systemChromeMaterialDark
    }
}
