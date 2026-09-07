import Foundation
import Combine
import Security

public struct RegisteredModel: Identifiable, Hashable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let provider: String
    public let modelRef: String
    public let dims: Int
    public let storedDims: Int
    public let storageKind: String
    public let indexKind: String
    public let tableName: String
    public let isDefault: Bool
    public let modelId: String?

    public init(
        slug: String,
        provider: String,
        modelRef: String,
        dims: Int,
        storedDims: Int,
        storageKind: String,
        indexKind: String,
        tableName: String,
        isDefault: Bool,
        modelId: String? = nil
    ) {
        self.slug = slug
        self.provider = provider
        self.modelRef = modelRef
        self.dims = dims
        self.storedDims = storedDims
        self.storageKind = storageKind
        self.indexKind = indexKind
        self.tableName = tableName
        self.isDefault = isDefault
        self.modelId = modelId
    }
}

enum PostgresStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

/// Owns the lifecycle of a private Postgres cluster dedicated to this app:
/// its own data directory, its own port, its own database. Never touches any
/// system-wide Postgres install (brew services, /var/lib/postgresql, etc).
@MainActor
final class PostgresService: ObservableObject {
    @Published private(set) var status: PostgresStatus = .stopped
    @Published private(set) var logs: [LogLine] = []

    /// Fixed, non-default port so this never collides with a system Postgres on 5432.
    let port = 14824
    let databaseName = "garage-rag"

    private let runner = ProcessRunner()
    private let maxLogLines = 2000
    private var cachedPassword: String?

    func connectionURL() throws -> String {
        let username = try percentEncode(NSUserName())
        let password = try percentEncode(postgresPassword())
        return "postgresql+psycopg://\(username):\(password)@localhost:\(port)/\(databaseName)"
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    private var isInitialized: Bool {
        FileManager.default.fileExists(atPath: Paths.pgDataDir.appendingPathComponent("PG_VERSION").path)
    }

    /// Runs initdb into Paths.pgDataDir if it hasn't been created yet.
    func ensureInitialized() throws {
        guard !isInitialized else { return }
        try FileManager.default.createDirectory(at: Paths.pgDataDir, withIntermediateDirectories: true)
        let password = try postgresPassword()
        let passwordFile = Paths.appSupportDir
            .appendingPathComponent(".initdb-password-\(UUID().uuidString)")
        try Data((password + "\n").utf8).write(to: passwordFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordFile.path
        )
        defer { try? FileManager.default.removeItem(at: passwordFile) }

        let (status, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("initdb"),
            arguments: [
                "-D", Paths.pgDataDir.path,
                "-U", NSUserName(),
                "-E", "UTF8",
                "--auth=scram-sha-256",
                "--pwfile=\(passwordFile.path)",
                "--no-instructions",
            ],
            environment: runtimeEnvironment(password: password)
        )
        for rawLine in output.split(separator: "\n") {
            appendLog(LogLine(stream: .stdout, text: String(rawLine), source: "initdb"))
        }
        guard status == 0 else {
            throw PostgresError.initFailed(output)
        }
    }

    func start() async throws {
        guard status == .stopped || isFailed else { return }
        status = .starting
        do {
            try ensureInitialized()
        } catch {
            status = .failed("\(error)")
            throw error
        }

        try FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)

        do {
            try runner.run(
                executable: Paths.postgresTool("postgres"),
                arguments: [
                    "-D", Paths.pgDataDir.path,
                    "-p", String(port),
                    "-c", "listen_addresses=localhost",
                    "-c", "unix_socket_directories=",
                    "-c", "logging_collector=off",
                ],
                environment: runtimeEnvironment(),
                source: "postgres"
            ) { [weak self] line in
                self?.appendLog(line)
            }
        } catch {
            status = .failed("failed to launch postgres: \(error.localizedDescription)")
            throw error
        }

        let ready = await waitUntilReady(timeout: 30)
        guard ready else {
            status = .failed("postgres did not become ready within 20s")
            throw PostgresError.startupTimeout
        }

        try await ensureDatabaseExists(password: try postgresPassword())
        status = .running
    }

    /// Fire-and-forget SIGTERM for app-quit paths that can't await cleanup
    /// (see AppDelegate.applicationWillTerminate). Prefer stop() elsewhere.
    func terminateImmediately() {
        runner.terminate()
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        runner.terminate()
        // Poll briefly for the process to actually exit rather than assuming.
        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        status = .stopped
    }

    /// Drops and recreates the app's private database, preserving the cluster
    /// and its Keychain-managed superuser credential.
    func resetDatabase() throws {
        try requireRunning()
        let password = try postgresPassword()
        try dropDatabase(password: password)
        try createDatabase(password: password)
        appendLog(LogLine(stream: .stdout, text: "reset database \(databaseName)", source: "postgres"))
    }

    /// Writes a portable PostgreSQL custom-format dump of the app's database.
    func backupDatabase(to destination: URL) throws {
        try requireRunning()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (dumpStatus, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("pg_dump"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(),
                "--format=custom", "--no-owner", "--no-privileges",
                "--file", destination.path, databaseName,
            ],
            environment: runtimeEnvironment(password: try postgresPassword())
        )
        guard dumpStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw PostgresError.other("pg_dump failed: \(output)")
        }
        appendLog(LogLine(stream: .stdout, text: "backed up database to \(destination.path)", source: "pg_dump"))
    }

    /// Replaces the app's database with a PostgreSQL custom-format dump.
    func restoreDatabase(from source: URL) throws {
        try requireRunning()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PostgresError.other("backup file does not exist: \(source.path)")
        }

        let password = try postgresPassword()
        try dropDatabase(password: password)
        try createDatabase(password: password)
        let (restoreStatus, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("pg_restore"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(),
                "--no-owner", "--no-privileges", "--exit-on-error",
                "--dbname", databaseName, source.path,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard restoreStatus == 0 else {
            throw PostgresError.other("pg_restore failed: \(output)")
        }
        appendLog(LogLine(stream: .stdout, text: "restored database from \(source.path)", source: "pg_restore"))
    }

    /// Fetches all registered embedding models directly from the backing database.
    func listRegisteredModels() throws -> [RegisteredModel] {
        try requireRunning()
        let password = try postgresPassword()
        let sql = "SELECT slug, provider, model_ref, dims, stored_dims, storage_kind, index_kind, table_name, is_default, coalesce(model_id, '') FROM embedding_models ORDER BY id;"
        let (status, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAF\t", "-c", sql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard status == 0 else {
            throw PostgresError.other("psql query failed: \(output)")
        }
        var models: [RegisteredModel] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 9 else { continue }
            let slug = parts[0]
            let provider = parts[1]
            let modelRef = parts[2]
            let dims = Int(parts[3]) ?? 0
            let storedDims = Int(parts[4]) ?? 0
            let storageKind = parts[5]
            let indexKind = parts[6]
            let tableName = parts[7]
            let isDefault = parts[8] == "t" || parts[8] == "true"
            let modelId = parts.count >= 10 && !parts[9].isEmpty ? parts[9] : nil
            models.append(RegisteredModel(
                slug: slug,
                provider: provider,
                modelRef: modelRef,
                dims: dims,
                storedDims: storedDims,
                storageKind: storageKind,
                indexKind: indexKind,
                tableName: tableName,
                isDefault: isDefault,
                modelId: modelId
            ))
        }
        return models
    }

    /// Fetches all registered ingest sources directly from the backing database.
    func listRegisteredSources() throws -> [RegisteredSource] {
        try requireRunning()
        let password = try postgresPassword()
        let sql = "SELECT slug, kind, root, default_class::text, default_trust::text, allow_cloud_enrichment, enabled FROM sources ORDER BY id;"
        let (status, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAF\t", "-c", sql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard status == 0 else {
            throw PostgresError.other("psql query failed: \(output)")
        }
        var sources: [RegisteredSource] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let slug = parts[0]
            let kind = parts[1]
            let root = parts[2]
            let corpusClass = parts[3]
            let trust = parts[4]
            let allowCloud = parts[5] == "t" || parts[5] == "true"
            let enabled = parts[6] == "t" || parts[6] == "true"
            sources.append(RegisteredSource(
                slug: slug,
                kind: kind,
                root: root,
                corpusClass: corpusClass,
                trust: trust,
                allowCloudEnrichment: allowCloud,
                enabled: enabled,
                includeCode: false,
                origin: .database
            ))
        }
        return sources
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func requireRunning() throws {
        guard status == .running else {
            throw PostgresError.other("Postgres must be running to manage the database")
        }
    }

    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (code, messages) = ProcessRunner.runSync(
                executable: Paths.postgresTool("pg_isready"),
                arguments: ["-h", "localhost", "-p", String(port)]
            )
            if code == 0 { return true }
            appendLog(LogLine(stream: .stdout, text: String(messages), source: "pg_isready"))
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func ensureDatabaseExists(password: String) async throws {
        let (checkStatus, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", "postgres",
                "-tAc", "SELECT 1 FROM pg_database WHERE datname = '\(databaseName)'",
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard checkStatus == 0 else {
            throw PostgresError.other("could not query pg_database: \(output)")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return
        }
        try createDatabase(password: password)
    }

    private func createDatabase(password: String) throws {
        let (createStatus, createOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("createdb"),
            arguments: ["-h", "localhost", "-p", String(port), "-U", NSUserName(), databaseName],
            environment: runtimeEnvironment(password: password)
        )
        guard createStatus == 0 else {
            throw PostgresError.other("createdb failed: \(createOutput)")
        }
        appendLog(LogLine(stream: .stdout, text: "created database \(databaseName)", source: "postgres"))
    }

    private func dropDatabase(password: String) throws {
        let (dropStatus, dropOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("dropdb"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(),
                "--force", databaseName,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard dropStatus == 0 else {
            throw PostgresError.other("dropdb failed: \(dropOutput)")
        }
    }

    /// Environment postgres needs to find its own dylibs and pgvector's shared
    /// object when running from a relocated (vendored) bundle.
    private func runtimeEnvironment(password: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = Paths.postgresLibDir.path
        // Without this, postgres fails at startup on macOS with "FATAL:
        // postmaster became multithreaded during startup" — some locale
        // initialization on this platform spins up threads before postgres's
        // fork-safety check runs. Confirmed via direct testing; the postgres
        // HINT suggesting LC_ALL is correct.
        env["LC_ALL"] = "C"
        if let password {
            env["PGPASSWORD"] = password
        }
        return env
    }

    private func postgresPassword() throws -> String {
        if let cachedPassword {
            return cachedPassword
        }
        do {
            if let storedPassword = try KeychainPostgresPassword.load() {
                cachedPassword = storedPassword
                return storedPassword
            }
        } catch {
            // In headless/test environments without keychain access, fall through to in-memory generation
        }

        let generatedPassword = try KeychainPostgresPassword.generate()
        do {
            try KeychainPostgresPassword.save(generatedPassword)
        } catch {
            if let storedPassword = try? KeychainPostgresPassword.load() {
                cachedPassword = storedPassword
                return storedPassword
            }
            // In headless/test environments without keychain access, keep in-memory
            cachedPassword = generatedPassword
            return generatedPassword
        }
        cachedPassword = generatedPassword
        return generatedPassword
    }

    private func percentEncode(_ value: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw PostgresError.other("could not encode Postgres credential for its connection URL")
        }
        return encoded
    }
}

private enum KeychainPostgresPassword {
    private static let service = "com.rickmark.garage.postgres"
    private static var account: String { NSUserName() }
    private static let passwordLength = 32
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    private static func openLoginKeychain() -> SecKeychain? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(home)/Library/Keychains/login.keychain-db",
            "\(home)/Library/Keychains/login.keychain",
        ]
        for path in candidatePaths {
            var keychain: SecKeychain?
            let status = SecKeychainOpen(path, &keychain)
            if status == errSecSuccess, let keychain {
                return keychain
            }
        }
        return nil
    }

    static func load() throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        if let keychain = openLoginKeychain() {
            query[kSecUseKeychain] = keychain
            query[kSecMatchSearchList] = [keychain] as CFArray
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw PostgresError.other("could not read Postgres password from Keychain (OSStatus \(status))")
        }
        return password
    }

    static func save(_ password: String) throws {
        var newItem: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let keychain = openLoginKeychain()
        if let keychain {
            newItem[kSecUseKeychain] = keychain
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PostgresError.other("could not save Postgres password in Keychain (OSStatus \(addStatus))")
        }
    }

    static func generate() throws -> String {
        var password = ""
        while password.count < passwordLength {
            var bytes = [UInt8](repeating: 0, count: passwordLength)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw PostgresError.other("could not generate Postgres password (OSStatus \(status))")
            }
            for byte in bytes where byte < 248 && password.count < passwordLength {
                password.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return password
    }
}

enum PostgresError: LocalizedError {
    case initFailed(String)
    case startupTimeout
    case other(String)

    var errorDescription: String? {
        switch self {
        case .initFailed(let output): "initdb failed:\n\(output)"
        case .startupTimeout: "postgres did not report ready in time"
        case .other(let message): message
        }
    }
}
