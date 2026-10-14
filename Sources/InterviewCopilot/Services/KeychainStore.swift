import Foundation
import Security
import LocalAuthentication

enum KeychainStore {
    private static let accounts = ["api-key", "aitunnel"]
    private static func query(account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.interviewcopilot", kSecAttrAccount as String: account] }
    static func hasStoredKey() throws -> Bool {
        let context = LAContext(); context.interactionNotAllowed = true
        for account in accounts {
            var request = query(account: account)
            request[kSecReturnAttributes as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            request[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw keychainError(status) }
            return true
        }
        return false
    }
    static func read() throws -> String? {
        for account in accounts {
            var request = query(account: account)
            request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { throw keychainError(status) }
            return key
        }
        return nil
    }
    static func save(_ value: String) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { return }
        let target = query(account: accounts[0])
        var request = target; request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(target as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать или сохранить ключ в Keychain (\(status))"])
    }
}
