import AVFoundation
import SwiftUI
import UIKit

/// 一口气念几分钟会把用户绑在音频上，1200 字足够听出语气又不会失控。
private let speechCharacterLimit = 1200

/// 朗读状态集中在这里，气泡只关心「是不是我在读」。
@MainActor
final class SpeechPlayer: ObservableObject {
    static let shared = SpeechPlayer()

    @Published private(set) var speakingItemID: UUID?

    private let synthesizer = AVSpeechSynthesizer()
    private let bridge = SpeechBridge()

    private init() {
        bridge.owner = self
        synthesizer.delegate = bridge
    }

    var isSpeaking: Bool { speakingItemID != nil }

    func toggle(id: UUID, text: String) {
        if speakingItemID == id {
            stop()
            return
        }
        stop()
        start(id: id, text: text)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingItemID = nil
    }

    fileprivate func clearSpeakingItem() {
        speakingItemID = nil
    }

    private func start(id: UUID, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let clipped = body.count > speechCharacterLimit
            ? String(body.prefix(speechCharacterLimit)) + "…"
            : body
        let utterance = AVSpeechUtterance(string: clipped)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5
        speakingItemID = id
        synthesizer.speak(utterance)
    }
}

/// AVSpeechSynthesizerDelegate 是 NSObject 协议，枚举与 class 都不能直接声明为它，
/// 所以单独拉一个桥接对象，回调里再回主线程改状态。
private final class SpeechBridge: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: SpeechPlayer?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.owner?.clearSpeakingItem()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.owner?.clearSpeakingItem()
        }
    }
}

enum MessageActionError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "写入工作目录失败：\(reason)"
        }
    }
}

enum MessageActions {
    static func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// 把一条回复存成 md 落进工作目录，这样它能被 agent 自己再读到、也能在「文件」App 里找到。
    static func saveTextToWorkspace(_ text: String) throws -> URL {
        let manager = FileManager.default
        guard let base = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw MessageActionError.writeFailed("找不到 Documents 目录")
        }
        let folder = base.appendingPathComponent("workspace", isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw MessageActionError.writeFailed(error.localizedDescription)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent(formatter.string(from: Date()) + ".md")

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MessageActionError.writeFailed(error.localizedDescription)
        }
        return url
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
