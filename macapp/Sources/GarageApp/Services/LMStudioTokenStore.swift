import Foundation
import Security

enum LMStudioTokenStore {
    private static let service = "dev.rickmark.garage.lmstudio"
    private static let account = "api-token"

    static func load() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw LMStudioTokenError.keychainRead(status)
        }
        return token
    }

    static func save(_ token: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw LMStudioTokenError.keychainWrite(updateStatus)
        }

        var newItem = query
        for (key, value) in attributes {
            newItem[key] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw LMStudioTokenError.keychainWrite(addStatus)
        }
    }

    static func remove() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LMStudioTokenError.keychainDelete(status)
        }
    }
}

enum LMStudioTokenError: LocalizedError {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)
    case keychainDelete(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainRead(let status):
            "could not read LM Studio API token from Keychain (OSStatus \(status))"
        case .keychainWrite(let status):
            "could not save LM Studio API token in Keychain (OSStatus \(status))"
        case .keychainDelete(let status):
            "could not remove LM Studio API token from Keychain (OSStatus \(status))"
        }
    }
}
