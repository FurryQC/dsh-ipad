import CoreImage
import ReplayKit
import UIKit
import UserNotifications

/// 屏幕广播扩展：系统把屏幕画面按帧喂进来，这里按间隔抽一帧 → 交给 DeepSeek 识别 → 发本地通知。
///
/// 独立进程，读不到主 App 的 UserDefaults / 钥匙串，所以配置与 key 都从 App Group 容器取。
final class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: nil)
    private var lastSentAt = Date.distantPast
    private var inFlight = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 通知权限必须由主 App 提前申请，扩展这里只能直接用。
    }

    override func broadcastFinished() {

    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let config = WatchShared.load()
        guard config.enabled, !inFlight else { return }
        let interval = max(1.0, min(5.0, config.intervalSeconds))
        guard Date().timeIntervalSince(lastSentAt) >= interval else { return }
        guard let jpeg = Self.makeJPEG(from: sampleBuffer, context: ciContext) else { return }

        lastSentAt = Date()
        inFlight = true
        Task {
            defer { inFlight = false }
            do {
                let text = try await WatchVision.ask(jpegBase64: jpeg.base64EncodedString(), config: config)
                WatchShared.recordResult(text)
                await Self.postNotification(text, config: config)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                WatchShared.recordResult("错误：" + message)
                await Self.postNotification("识别失败：" + message, config: config)
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
