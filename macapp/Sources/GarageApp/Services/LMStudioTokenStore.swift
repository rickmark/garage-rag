import Foundation
import Security
import PythonXPCService

/// Detects whether the code is currently running within a test environment.
public var isRunningInTestEnvironment: Bool {
    NSClassFromString("XCTestCase") != nil ||
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
    ProcessInfo.processInfo.environment["TEST_WORKSPACE"] != nil ||
    ProcessInfo.processInfo.environment["TEST_SRCDIR"] != nil ||
    ProcessInfo.processInfo.environment["BAZEL_TEST"] != nil
}

public protocol LMStudioTokenStoring: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func remove() throws
}

public final class KeychainLMStudioTokenStore: LMStudioTokenStoring, @unchecked Sendable {
    private let service = "me.rickmark.garage-rag.lmstudio"
    private let account = "api-token"

    public init() {}

    public func load() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
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

    public func save(_ token: String) throws {
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

    public func remove() throws {
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

public final class InMemoryLMStudioTokenStore: LMStudioTokenStoring, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()

    public init(initialToken: String? = nil) {
        self.token = initialToken
    }

    public func load() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func save(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = nil
    }
}

public enum LMStudioTokenStore {
    private static let lock = NSLock()
    private static var _storage: LMStudioTokenStoring?

    public static var storage: LMStudioTokenStoring {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let _storage {
                return _storage
            }
            // An overridden data folder (UI tests) stays off the Keychain as well: the real token is not
            // the test's to read, and a rebuilt app would wait on a Keychain access prompt.
            let isolated = isRunningInTestEnvironment || GarageAppGroup.dataDirectoryOverride != nil
            let defaultStore: LMStudioTokenStoring = isolated ? InMemoryLMStudioTokenStore() : KeychainLMStudioTokenStore()
            _storage = defaultStore
            return defaultStore
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _storage = newValue
        }
    }

    public static func load() throws -> String? {
        try storage.load()
    }

    public static func save(_ token: String) throws {
        try storage.save(token)
    }

    public static func remove() throws {
        try storage.remove()
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
