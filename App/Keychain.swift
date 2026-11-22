import Foundation
import Security

/// API Key 存在 Keychain 里，不落 UserDefaults、不进会话文件。
enum Keychain {
    private static let service = "com.dsh.ipad"
    private static let account = "api-key"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    /// 把 API key 写进钥匙串。返回是否成功 —— 无签名构建上 SecItemAdd 可能返回 -34018，
    /// 失败时界面要告诉用户「没存上」，否则用户以为存了、重启后 key 就没了。
    @discardableResult
    static func saveAPIKey(_ value: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return true }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            print("keychain save failed: \(status)")
            return false
        }
        return true
    }
}
