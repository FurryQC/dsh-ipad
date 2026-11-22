import CoreImage
import ReplayKit
import UIKit
import UserNotifications

/// 屏幕广播扩展。
///
/// 落地的方案：**不依赖 App Group**。
/// 重签时如果只给主 App 注入了 `group.com.dsh.qc`，扩展里
/// `containerURL(forSecurityApplicationGroupIdentifier:)` 和共享 UserDefaults 全是 nil
/// （b29 的弹窗已经证实），所以扩展改成：
///   1. 启动时从主 App 的 loopback 服务（127.0.0.1:56290）取一次配置；
///   2. 自己按间隔截帧、直接调 DeepSeek（flash + 推理关）、自己发系统通知。
/// 全程不需要任何 entitlement。
final class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: nil)
    private var config: WatchShared.Config?
    private var lastFrameAt = Date.distantPast
    private var frameCount = 0
    private var sentCount = 0
    private var inFlight = false
    private var announcedFirstFrame = false
    private var announcedFirstSend = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 先把「能不能发通知」当硬门槛：识别结果只能靠通知送到用户眼前，
        // 没授权就等于白跑；这里用系统错误框把原因直接摆到脸上。
        if !Self.notificationAuthorized() {
            finishBroadcastWithError(Self.watchError(
                "扩展跑起来了，但 DSH 的通知权限没开 —— 识别结果没地方显示，所以先停下。\n\n请到：设置 → 通知 → DSH → 打开「允许通知」（横幅也打开）。\n然后在 App 的「屏幕识别」页点一次「检查权限」，确认变成「已允许」再重新开始广播。"
            ))
            return
        }

        let outcome = WatchConfigClient.fetch()
        switch outcome {
        case .success(let loaded):
            config = loaded
            diag { d in
                d.groupOK = WatchShared.groupAvailable
                d.configEnabled = loaded.enabled
                d.frames = 0
                d.sent = 0
                d.lastError = ""
            }
            Self.notifyNow("DSH 屏幕识别 · 已连上 App",
                           "配置已取到（每 \(Int(loaded.intervalSeconds)) 秒一帧，模型 \(loaded.model)）。开始识别。")
        case .failure(let failure):
            let message = failure.message
            diag { d in
                d.groupOK = WatchShared.groupAvailable
                d.configEnabled = false
                d.lastError = message
            }
            finishBroadcastWithError(Self.watchError(
                "扩展已启动，但没能从 App 取到配置：\(message)。\n请回到 App 的「屏幕识别」页，确认已点过「保存配置」，再点红色圆钮开始；App 在前台时这个通道才开着。"
            ))
        }
    }

    override func broadcastFinished() {
        diag { d in
            d.frames = self.frameCount
            d.sent = self.sentCount
        }
        Self.notifyNow("DSH 屏幕识别 · 已停止", "收到 \(frameCount) 帧画面，发出 \(sentCount) 次识别。")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let config else { return }
        guard !inFlight else { return }

        frameCount += 1
        if frameCount == 1 && !announcedFirstFrame {
            announcedFirstFrame = true
            Self.notifyNow("DSH 屏幕识别 · 收到画面", "第一帧已到，开始按间隔识别。")
        }

        let interval = max(1.0, min(5.0, config.intervalSeconds))
        guard Date().timeIntervalSince(lastFrameAt) >= interval else { return }
        guard let jpeg = Self.makeJPEG(from: sampleBuffer, context: ciContext) else { return }
        lastFrameAt = Date()
        inFlight = true

        let base64 = jpeg.base64EncodedString()
        let snapshot = config
        Task { [weak self] in
            defer { self?.inFlight = false }
            do {
                let answer = try await WatchVision.ask(jpegBase64: base64, config: snapshot)
                let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                await MainActor.run { self?.sentCount += 1 }
                if snapshot.notify {
                    Self.notifyNow("DSH 屏幕识别", String(text.prefix(300)))
                }
                if let self {
                    self.diag { d in
                        d.frames = self.frameCount
                        d.sent = self.sentCount
                        d.configEnabled = true
                        d.lastError = ""
                    }
                }
                if !(self?.announcedFirstSend ?? true) {
                    self?.announcedFirstSend = true
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if let self {
                    self.diag { d in
                        d.frames = self.frameCount
                        d.sent = self.sentCount
                        d.lastError = message
                    }
                }
                Self.notifyNow("DSH 屏幕识别 · 这次没成", message)
            }
        }
    }

    /// 配置全在扩展内存里，诊断只往共享容器写（能写就写，写不进也不影响识别）。
    private func diag(_ mutate: (inout WatchShared.Diag) -> Void) {
        guard WatchShared.groupAvailable else { return }
        WatchShared.updateDiag(mutate)
    }

    private static func watchError(_ message: String) -> NSError {
        NSError(domain: "com.dsh.qc.broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 同步查一次通知授权状态（扩展里没有 UI，只能这样问）。
    private static func notificationAuthorized() -> Bool {
        let center = UNUserNotificationCenter.current()
        var authorized = false
        let semaphore = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                authorized = true
            default:
                authorized = false
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
        return authorized
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
