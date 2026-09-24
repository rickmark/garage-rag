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
    /// The password's home: `postgres-password` in the data folder, owner-only (0600). Every Garage
    /// process reaches that folder through the app group (the App Store and Developer ID builds,
    /// their XPC services and the `garage` / `garage-mcp` launchers), and reading a file never
    /// raises a Keychain access prompt, which used to freeze the window at launch after each re-signed
    /// release and lock one build out of the other's item. A `--data-directory` folder (UI tests) has
    /// its own, so an isolated cluster never reads or replaces the real database's password.
    public static var passwordFile: URL {
        GarageAppGroup.dataDirectory.appendingPathComponent(passwordFileName, isDirectory: false)
    }
    public static let passwordFileName = "postgres-password"

    /// Where builds before 1.5 kept the password: a generic password in the legacy file keychain,
    /// whose per-binary access list prompts every other binary. Read once to migrate it into
    /// `passwordFile`, never written.
    public static let keychainService = "com.rickmark.garage.postgres"
    public static var keychainAccount: String { NSUserName() }
    public static var username: String { NSUserName() }

    public enum EndpointError: LocalizedError {
        case keychain(OSStatus)
        case passwordFile(URL, String)
        case encoding

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "could not read the Garage database password from the Keychain: \(reason)"
            case .passwordFile(let file, let reason):
                return "could not use the Garage database password file \(file.path): \(reason)"
            case .encoding:
                return "could not encode the Garage database connection URL"
            }
        }
    }

    /// The password the app stored, or nil if the app has not created the cluster (or not yet moved
    /// an older build's password out of the Keychain). Only reads a file, so it never prompts.
    public static func readPassword() throws -> String? {
        try readPassword(from: passwordFile)
    }

    public static func readPassword(from file: URL) throws -> String? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw EndpointError.passwordFile(file, error.localizedDescription)
        }
        // Tighten a file someone loosened; the password opens the whole corpus.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let mode = attributes[.posixPermissions] as? Int, mode & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EndpointError.passwordFile(file, "it is not UTF-8")
        }
        let password = text.trimmingCharacters(in: .newlines)
        guard !password.isEmpty else {
            throw EndpointError.passwordFile(file, "it is empty")
        }
        return password
    }

    /// Stores `password` in `passwordFile`, replacing what is there. The file is created owner-only
    /// under a temporary name and renamed into place, so no reader ever sees it partly written or
    /// with wider permissions.
    public static func writePassword(_ password: String) throws {
        try writePassword(password, to: passwordFile)
    }

    public static func writePassword(_ password: String, to file: URL) throws {
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw EndpointError.passwordFile(file, error.localizedDescription)
        }
        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw EndpointError.passwordFile(file, String(cString: strerror(errno)))
        }
        let bytes = Array((password + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temporary.path, file.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw EndpointError.passwordFile(file, reason)
        }
    }

    /// The password an older build left in the legacy keychain, or nil when there is none. May show
    /// a Keychain access prompt and block until it is answered, so never call it on the main thread.
    public static func readLegacyKeychainPassword() throws -> String? {
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

    /// `--data-directory <path>`: run on this data folder instead of the real one, with no migration,
    /// no link and a separate Keychain item. For UI tests, which reset the database.
    public static let dataDirectoryArgument = "--data-directory"
}
