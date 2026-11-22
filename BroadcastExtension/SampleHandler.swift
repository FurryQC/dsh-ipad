import CoreImage
import ReplayKit
import UIKit
import UserNotifications

/// 屏幕广播扩展：系统把屏幕画面按帧喂进来，这里按间隔抽一帧 → 交给 DeepSeek 识别 → 发本地通知。
///
/// 独立进程，读不到主 App 的 UserDefaults / 钥匙串，所以配置与 key 都从 App Group 容器取。
/// 每一步都往 `WatchShared.diag` 写状态，主 App 的设置页能把「卡在哪一步」显示出来。
final class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: nil)
    private var lastSentAt = Date.distantPast
    private var inFlight = false
    private var frameCount = 0
    private var lastDiagWrite = Date.distantPast

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let config = WatchShared.load()
        WatchShared.updateDiag { diag in
            diag.groupOK = WatchShared.groupAvailable
            diag.configEnabled = config.enabled
            diag.frames = 0
            diag.sent = 0
            diag.lastError = config.enabled
                ? "广播已启动，等第一帧"
                : "扩展起来了但读到的配置是「未启用」—— 多半是重签时没给 App Group（group.com.dsh.qc）"
        }
    }

    override func broadcastFinished() {
        WatchShared.updateDiag { diag in
            diag.lastError = "广播已停止（收到 \(diag.frames) 帧，发出 \(diag.sent) 次）"
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        frameCount += 1
        let config = WatchShared.load()
        writeDiagIfNeeded(config: config)

        guard config.enabled else { return }
        guard !inFlight else { return }
        let interval = max(1.0, min(5.0, config.intervalSeconds))
        guard Date().timeIntervalSince(lastSentAt) >= interval else { return }
        guard let jpeg = Self.makeJPEG(from: sampleBuffer, context: ciContext) else {
            WatchShared.updateDiag { $0.lastError = "帧转 JPEG 失败（收到 \(self.frameCount) 帧但转不出来）" }
            return
        }

        lastSentAt = Date()
        inFlight = true
        let framesNow = frameCount
        Task {
            defer { inFlight = false }
            do {
                let text = try await WatchVision.ask(jpegBase64: jpeg.base64EncodedString(), config: config)
                WatchShared.recordResult(text)
                WatchShared.updateDiag { diag in
                    diag.groupOK = WatchShared.groupAvailable
                    diag.configEnabled = true
                    diag.frames = framesNow
                    diag.sent += 1
                    diag.lastError = ""
                }
                await Self.postNotification(text, config: config)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                WatchShared.recordResult("错误：" + message)
                WatchShared.updateDiag { diag in
                    diag.frames = framesNow
                    diag.lastError = "识别失败：" + message
                }
                await Self.postNotification("识别失败：" + message, config: config)
            }
        }
    }

    /// 每帧都写 UserDefaults 太重，最多 2 秒写一次。
    private func writeDiagIfNeeded(config: WatchShared.Config) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagWrite) > 2 else { return }
        lastDiagWrite = now
        let framesNow = frameCount
        WatchShared.updateDiag { diag in
            diag.groupOK = WatchShared.groupAvailable
            diag.configEnabled = config.enabled
            diag.frames = framesNow
            if !config.enabled && diag.lastError.isEmpty {
                diag.lastError = "读到的配置是「未启用」—— App Group 可能没生效"
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

    private static func postNotification(_ text: String, config: WatchShared.Config) async {
        guard config.notify else { return }
        let content = UNMutableNotificationContent()
        content.title = "DSH 屏幕识别"
        content.body = String(text.prefix(300))
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 扩展里加不了通知（权限没给或系统限制）时，内容已经在 App Group 里，主 App 能看到。
        }
    }
}
