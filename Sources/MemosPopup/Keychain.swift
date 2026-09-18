import Foundation
import Security

enum Keychain {
    static let service = "app.memos.popup.token"
    static func read(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query.merging(attributes) { _, value in value }
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(new as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func failure(_ code: OSStatus) -> NSError {
        NSError(domain: "MemosKeychain", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "无法访问 macOS 钥匙串（\(code)），请允许应用保存 Token 后重试。"])
    }
}
