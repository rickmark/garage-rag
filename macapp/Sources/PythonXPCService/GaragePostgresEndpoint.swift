import Darwin
import Foundation
import Security

/// Where the app's private Postgres listens and where its password lives. Shared by
/// the app, which owns the cluster, and the bundled `garage` / `garage-mcp`
/// launchers, which connect to it from processes the app did not start (a terminal,
/// an MCP client spawning `garage-mcp`).
public enum GaragePostgresEndpoint {
    /// Fixed, non-default port so this never collides with a system Postgres on 5432.
    public static let port = 14824
    public static let databaseName = "garage-rag"
    public static let keychainService = "com.rickmark.garage.postgres"
    public static var keychainAccount: String { NSUserName() }
    public static var username: String { NSUserName() }

    public enum EndpointError: LocalizedError {
        case keychain(OSStatus)
        case encoding

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "could not read the Garage database password from the Keychain: \(reason)"
            case .encoding:
                return "could not encode the Garage database connection URL"
            }
        }
    }

    /// The password the app stored, or nil if the app has never created the cluster.
    public static func readPassword() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw EndpointError.keychain(status)
        }
        return password
    }

    /// `postgresql+psycopg://…` (SQLAlchemy, what garage_rag reads) or `postgresql://…`.
    public static func connectionURL(password: String, scheme: String = "postgresql+psycopg") throws -> String {
        guard let user = percentEncode(username), let secret = percentEncode(password) else {
            throw EndpointError.encoding
        }
        return "\(scheme)://\(user):\(secret)@localhost:\(port)/\(databaseName)"
    }

    /// True when something accepts TCP connections on the Postgres port. A refused
    /// connection returns at once, so this is cheap to poll.
    public static func isAcceptingConnections() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func percentEncode(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

/// How the launchers start the app when its database is not running.
public enum GarageAppLaunch {
    /// Start the services and stay in the menu bar without opening the main window.
    public static let backgroundArgument = "--background"

    /// `--after-database-reset <pid>`: the app instance `pid` deleted the database and launched this
    /// one to create a new one. This instance starts nothing until `pid` has quit.
    public static let databaseResetArgument = "--after-database-reset"
}
