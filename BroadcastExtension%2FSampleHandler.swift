import CoreImage
import ReplayKit
import UIKit
import UserNotifications

/// 屏幕广播扩展：只做一件事 —— 按间隔把一帧 JPEG 落进 App Group 共享容器。
///
/// 真正的网络请求由主 App 发（主 App 有钥匙串、有会话、能发通知），
/// 扩展里不碰 API key，也就少一处「读不到配置就整条链路静默失败」的坑。
final class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: nil)
    private var lastFrameAt = Date.distantPast
    private var frameCount = 0
    private var writtenCount = 0
    private var lastDiagWrite = Date.distantPast
    private var announcedFirstFrame = false
    private var announcedFirstWrite = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let config = WatchShared.load()
        let groupOK = WatchShared.groupAvailable
        WatchShared.updateDiag { diag in
            diag.groupOK = groupOK
            diag.configEnabled = config.enabled
            diag.frames = 0
            diag.sent = 0
            diag.lastError = config.enabled ? "广播已启动，等第一帧" : "扩展起来了但配置读到的是「未启用」"
        }

        // 这两条错误会由系统弹给用户，是「扩展到底跑没跑起来 / 能不能读到配置」最直接的证据：
        // 弹出来说明扩展活了；连弹窗都没有说明扩展根本没被系统拉起（重签时 appex 没签好）。
        let containerInfo = WatchShared.containerDiagnostics()
        if !groupOK {
            finishBroadcastWithError(Self.watchError(
                "扩展已启动，但拿不到 App Group（group.com.dsh.qc）。扩展这边：\(containerInfo)。重签时请把 group.com.dsh.qc 同时加到 com.dsh.qc 和 com.dsh.qc.broadcast。"
            ))
            return
        }
        if !config.enabled {
            finishBroadcastWithError(Self.watchError(
                "扩展已启动，但读到的配置是「未启用」。扩展这边：\(containerInfo)。回 App 的屏幕识别页点一次「保存配置」再试；如果反复如此，说明主 App 和扩展没共享同一个容器（重签时 group 只给了一边）。"
            ))
            return
        }

        Self.notifyNow("DSH 屏幕识别 · 扩展已启动", "共享容器可用；配置已启用，等第一帧画面。")
    }

    private static func watchError(_ message: String) -> NSError {
        NSError(domain: "com.dsh.qc.broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    override func broadcastFinished() {
        WatchShared.updateDiag { diag in
            diag.lastError = "广播已停止（收到 \(diag.frames) 帧，写入 \(self.writtenCount) 帧）"
        }
        Self.notifyNow("DSH 屏幕识别 · 已停止", "收到 \(frameCount) 帧画面，写入共享容器 \(writtenCount) 帧。")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        frameCount += 1
        let config = WatchShared.load()
        writeDiagIfNeeded(config: config)

        if frameCount == 1 && !announcedFirstFrame {
            announcedFirstFrame = true
            Self.notifyNow("DSH 屏幕识别 · 收到画面", "第 1 帧已到达，正在按间隔写入共享容器。")
        }

        // 配置读不到也照写：只要共享容器通着，主 App 就能拿到画面；
        // 容器不通的话 writeFrame 返回 false，诊断里会记下来。
        let interval = max(1.0, min(5.0, config.intervalSeconds))
        guard Date().timeIntervalSince(lastFrameAt) >= interval else { return }
        guard let jpeg = Self.makeJPEG(from: sampleBuffer, context: ciContext) else {
            WatchShared.updateDiag { $0.lastError = "帧转 JPEG 失败（收到 \(self.frameCount) 帧）" }
            return
        }
        lastFrameAt = Date()
        if WatchShared.writeFrame(jpeg) {
            writtenCount += 1
            if !announcedFirstWrite {
                announcedFirstWrite = true
                Self.notifyNow("DSH 屏幕识别 · 画面已写入", "主 App 会读走它、发给模型。")
            }
        } else {
            WatchShared.updateDiag { $0.lastError = "写不进共享容器 —— 重签时多半没给扩展加 App Group（group.com.dsh.qc）" }
        }
    }

    /// 每帧都写 UserDefaults 太重，最多 2 秒写一次。
    private func writeDiagIfNeeded(config: WatchShared.Config) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagWrite) > 2 else { return }
        lastDiagWrite = now
        let framesNow = frameCount
        let writtenNow = writtenCount
        WatchShared.updateDiag { diag in
            diag.groupOK = WatchShared.groupAvailable
            diag.configEnabled = config.enabled
            diag.frames = framesNow
            diag.sent = writtenNow
            if !config.enabled && diag.lastError.isEmpty {
                diag.lastError = "配置读到的是「未启用」"
            }
        }
    }

    private static func makeJPEG(from sampleBuffer: CMSampleBuffer, context: CIContext) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let maxWidth: CGFloat = 1024
        guard image.extent.width > 0 else { return nil }
        let scale = min(1, maxWidth / image.extent.width)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.6)
    }

    /// 诊断通知：不受用户的「发通知」开关影响，必须能看见。
    private static func notifyNow(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
