import Foundation
import Combine
import Security
import AppKit

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

public struct CorpusStats: Equatable, Sendable {
    public var sourcesCount: Int
    public var documentsCount: Int
    public var documentsOkCount: Int
    public var documentsFailedCount: Int
    public var totalChunks: Int
    public var embeddedChunks: Int
    public var totalSeenFiles: Int
    public var totalIndexedFiles: Int
    public var totalExpectedElements: Int
    public var modelStats: [ModelEmbeddingStats]
    public var lastUpdated: Date?

    public init(
        sourcesCount: Int = 0,
        documentsCount: Int = 0,
        documentsOkCount: Int = 0,
        documentsFailedCount: Int = 0,
        totalChunks: Int = 0,
        embeddedChunks: Int = 0,
        totalSeenFiles: Int = 0,
        totalIndexedFiles: Int = 0,
        totalExpectedElements: Int = 0,
        modelStats: [ModelEmbeddingStats] = [],
        lastUpdated: Date? = nil
    ) {
        self.sourcesCount = sourcesCount
        self.documentsCount = documentsCount
        self.documentsOkCount = documentsOkCount
        self.documentsFailedCount = documentsFailedCount
        self.totalChunks = totalChunks
        self.embeddedChunks = embeddedChunks
        self.totalSeenFiles = totalSeenFiles
        self.totalIndexedFiles = totalIndexedFiles
        self.totalExpectedElements = totalExpectedElements
        self.modelStats = modelStats
        self.lastUpdated = lastUpdated
    }

    public struct ModelEmbeddingStats: Identifiable, Hashable, Sendable {
        public var id: String { slug }
        public let slug: String
        public let tableName: String
        public let isDefault: Bool
        public let embeddedCount: Int

        public init(slug: String, tableName: String, isDefault: Bool, embeddedCount: Int) {
            self.slug = slug
            self.tableName = tableName
            self.isDefault = isDefault
            self.embeddedCount = embeddedCount
        }
    }

    public var uningestedElements: Int {
        if totalExpectedElements > 0 {
            return max(0, totalExpectedElements - documentsCount)
        }
        if totalSeenFiles > 0 {
            return max(0, totalSeenFiles - totalIndexedFiles)
        }
        return 0
    }

    public var totalEmbeddedAcrossAllModels: Int {
        modelStats.reduce(0) { $0 + $1.embeddedCount }
    }

    public var totalRequiredEmbeddingsAcrossAllModels: Int {
        modelStats.count * totalChunks
    }

    public var unembeddedChunks: Int {
        if modelStats.isEmpty {
            return totalChunks
        }
        return modelStats.reduce(0) { $0 + max(0, totalChunks - $1.embeddedCount) }
    }

    public var ingestionProgressFraction: Double {
        if totalExpectedElements > 0 {
            return min(1.0, max(0.0, Double(documentsCount) / Double(totalExpectedElements)))
        }
        if totalSeenFiles > 0 {
            return min(1.0, max(0.0, Double(totalIndexedFiles) / Double(totalSeenFiles)))
        }
        if documentsCount > 0 {
            return 1.0
        }
        return 0.0
    }

    public var embeddingProgressFraction: Double {
        let totalRequired = totalRequiredEmbeddingsAcrossAllModels
        guard totalRequired > 0 else {
            if totalChunks > 0 && embeddedChunks > 0 {
                return min(1.0, max(0.0, Double(embeddedChunks) / Double(totalChunks)))
            }
            return 0.0
        }
        return min(1.0, max(0.0, Double(totalEmbeddedAcrossAllModels) / Double(totalRequired)))
    }
}

enum PostgresStatus: Equatable {
    case stopped
    case starting
    case needsMigration
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
    @Published private(set) var pendingMigrations: [String] = []

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

    func standardConnectionURLString() throws -> String {
        let username = try percentEncode(NSUserName())
        let password = try percentEncode(postgresPassword())
        return "postgresql://\(username):\(password)@localhost:\(port)/\(databaseName)"
    }

    func standardConnectionURL() throws -> URL {
        let urlString = try standardConnectionURLString()
        guard let url = URL(string: urlString) else {
            throw PostgresError.other("could not create standard PostgreSQL connection URL: \(urlString)")
        }
        return url
    }

    @discardableResult
    func copyStandardConnectionURLToClipboard() throws -> String {
        let urlString = try standardConnectionURLString()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
        return urlString
    }

    @discardableResult
    func openInRegisteredHandler() throws -> Bool {
        let url = try standardConnectionURL()
        return NSWorkspace.shared.open(url)
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func clearLogs() {
        logs.removeAll()
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
            appendLog(PostgresLogParser.parse(rawText: String(rawLine), stream: .stdout, source: "initdb"))
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
                    "-c", "log_line_prefix=%m [%p] ",
                ],
                environment: runtimeEnvironment(),
                source: "postgres"
            ) { [weak self] line in
                let parsed = PostgresLogParser.parse(line: line)
                self?.appendLog(parsed)
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
        let pending = (try? fetchPendingMigrations()) ?? []
        self.pendingMigrations = pending
        if !pending.isEmpty {
            status = .needsMigration
        } else {
            status = .running
        }
    }

    /// Fire-and-forget SIGTERM for app-quit paths that can't await cleanup
    /// (see AppDelegate.applicationWillTerminate). Prefer stop() elsewhere.
    func terminateImmediately() {
        runner.terminate()
        Self.stopAnyRunningInstance()
    }

    func stop() async {
        guard status == .running || status == .needsMigration || status == .starting || runner.isRunning else {
            Self.stopAnyRunningInstance()
            return
        }
        status = .stopping
        runner.terminate()
        // Poll briefly for the process to actually exit rather than assuming.
        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if runner.isRunning {
            runner.forceKill()
        }
        Self.stopAnyRunningInstance()
        pendingMigrations = []
        status = .stopped
    }

    /// Stops any active Postgres server running against the app's pgdata directory,
    /// even if started by an earlier app instance or process.
    static func stopAnyRunningInstance() {
        let pidFile = Paths.pgDataDir.appendingPathComponent("postmaster.pid")
        guard FileManager.default.fileExists(atPath: pidFile.path) else { return }

        let pgCtl = Paths.postgresTool("pg_ctl")
        if FileManager.default.isExecutableFile(atPath: pgCtl.path) {
            _ = ProcessRunner.runSync(
                executable: pgCtl,
                arguments: ["stop", "-D", Paths.pgDataDir.path, "-m", "fast", "-s"]
            )
        }

        guard FileManager.default.fileExists(atPath: pidFile.path),
              let content = try? String(contentsOf: pidFile, encoding: .utf8),
              let firstLine = content.split(separator: "\n").first,
              let pid = Int32(firstLine.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return
        }

        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            var exited = false
            for _ in 0..<20 {
                usleep(50_000)
                if kill(pid, 0) != 0 {
                    exited = true
                    break
                }
            }
            if !exited && kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Drops and recreates the app's private database when running, or
    /// re-initializes the database cluster from scratch if stopped or failed.
    /// Preserves the Keychain-managed superuser credential.
    func resetDatabase() async throws {
        if status == .running || status == .needsMigration {
            let password = try postgresPassword()
            try dropDatabase(password: password)
            try createDatabase(password: password)
            appendLog(LogLine(stream: .stdout, text: "reset database \(databaseName)", source: "postgres"))
            let pending = (try? fetchPendingMigrations()) ?? []
            self.pendingMigrations = pending
            if !pending.isEmpty {
                status = .needsMigration
            } else {
                status = .running
            }
        } else {
            runner.terminate()
            for _ in 0..<20 where runner.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if FileManager.default.fileExists(atPath: Paths.pgDataDir.path) {
                try FileManager.default.removeItem(at: Paths.pgDataDir)
            }
            status = .stopped
            try await start()
            appendLog(LogLine(stream: .stdout, text: "re-initialized and reset database cluster \(databaseName)", source: "postgres"))
        }
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

    /// Fetches all registered ingest sources directly from the backing database along with their document counts.
    func listRegisteredSources() throws -> [RegisteredSource] {
        try requireRunning()
        let password = try postgresPassword()
        let sql = """
        SELECT s.slug, s.kind, s.root, s.default_class::text, s.default_trust::text, s.allow_cloud_enrichment, s.enabled, count(d.id), coalesce(s.expected_elements, 0)
        FROM sources s
        LEFT JOIN documents d ON d.source_id = s.id
        GROUP BY s.id, s.slug, s.kind, s.root, s.default_class, s.default_trust, s.allow_cloud_enrichment, s.enabled, s.expected_elements
        ORDER BY s.id;
        """
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
            let docCount = parts.count >= 8 ? (Int(parts[7]) ?? 0) : 0
            let expectedElements = parts.count >= 9 ? (Int(parts[8]) ?? 0) : 0
            sources.append(RegisteredSource(
                slug: slug,
                kind: kind,
                root: root,
                corpusClass: corpusClass,
                trust: trust,
                allowCloudEnrichment: allowCloud,
                enabled: enabled,
                includeCode: false,
                origin: .database,
                documentCount: docCount,
                expectedElements: expectedElements
            ))
        }
        return sources
    }

    /// Returns the list of unapplied migration SQL file names from Paths.schemaDir.
    func fetchPendingMigrations() throws -> [String] {
        let password = try postgresPassword()
        let schemaDir = Paths.schemaDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: schemaDir.path) else {
            return []
        }
        let sqlFiles = files.filter { $0.hasSuffix(".sql") }.sorted()
        if sqlFiles.isEmpty {
            return []
        }

        let sql = """
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = 'schema_migrations'
        );
        """
        let (checkStatus, checkOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAc", sql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard checkStatus == 0 else {
            throw PostgresError.other("failed to check schema_migrations table: \(checkOutput)")
        }

        let trimmedCheck = checkOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCheck != "t" && trimmedCheck != "true" {
            return sqlFiles
        }

        let appliedSql = "SELECT version FROM schema_migrations;"
        let (appliedStatus, appliedOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAc", appliedSql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard appliedStatus == 0 else {
            throw PostgresError.other("failed to query applied migrations: \(appliedOutput)")
        }

        let appliedVersions = Set(
            appliedOutput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        return sqlFiles.filter { file in
            let version = (file as NSString).deletingPathExtension
            return !appliedVersions.contains(version) && !appliedVersions.contains(file)
        }
    }

    /// Checks if there are unapplied migration SQL files in the schema directory.
    func hasPendingMigrations() throws -> Bool {
        return try !fetchPendingMigrations().isEmpty
    }

    /// Refreshes the pendingMigrations list and returns it.
    @discardableResult
    func refreshPendingMigrations() -> [String] {
        guard status == .running || status == .needsMigration else {
            pendingMigrations = []
            return []
        }
        let list = (try? fetchPendingMigrations()) ?? []
        self.pendingMigrations = list
        if !list.isEmpty {
            status = .needsMigration
        } else if status == .needsMigration {
            status = .running
        }
        return list
    }

    #if DEBUG
    func setPendingMigrationsForTesting(_ migrations: [String]) {
        self.pendingMigrations = migrations
    }
    #endif

    /// Applies all pending schema migrations and updates the database status.
    func applyMigrations() async throws {
        guard status == .running || status == .needsMigration else {
            throw PostgresError.other("Postgres is not running")
        }
        let password = try postgresPassword()
        let schemaDir = Paths.schemaDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: schemaDir.path) else {
            throw PostgresError.other("Schema directory not found at \(schemaDir.path)")
        }
        let sqlFiles = files.filter { $0.hasSuffix(".sql") }.sorted()

        let createTableSql = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version text PRIMARY KEY,
            applied_at timestamptz NOT NULL DEFAULT now()
        );
        """
        let (initTableStatus, initTableOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-c", createTableSql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard initTableStatus == 0 else {
            throw PostgresError.other("Failed to initialize schema_migrations table: \(initTableOutput)")
        }

        let appliedSql = "SELECT version FROM schema_migrations;"
        let (_, appliedOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAc", appliedSql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        let appliedVersions = Set(
            appliedOutput
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )

        for file in sqlFiles {
            let version = (file as NSString).deletingPathExtension
            if appliedVersions.contains(version) || appliedVersions.contains(file) {
                continue
            }
            let filePath = schemaDir.appendingPathComponent(file).path
            let (migStatus, migOutput) = ProcessRunner.runSync(
                executable: Paths.postgresTool("psql"),
                arguments: [
                    "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                    "-f", filePath,
                ],
                environment: runtimeEnvironment(password: password)
            )
            guard migStatus == 0 else {
                throw PostgresError.other("Migration \(file) failed: \(migOutput)")
            }

            let recordSql = "INSERT INTO schema_migrations (version) VALUES ('\(version)') ON CONFLICT (version) DO NOTHING;"
            _ = ProcessRunner.runSync(
                executable: Paths.postgresTool("psql"),
                arguments: [
                    "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                    "-c", recordSql,
                ],
                environment: runtimeEnvironment(password: password)
            )
            appendLog(LogLine(stream: .stdout, text: "applied migration: \(file)", source: "migrate"))
        }

        let pending = (try? fetchPendingMigrations()) ?? []
        self.pendingMigrations = pending
        if !pending.isEmpty {
            status = .needsMigration
        } else {
            status = .running
        }
    }

    /// Fetches document counts mapped by source slug.
    func fetchSourceDocumentCounts() throws -> [String: Int] {
        try requireRunning()
        let password = try postgresPassword()
        let sql = "SELECT s.slug, count(d.id) FROM sources s LEFT JOIN documents d ON d.source_id = s.id GROUP BY s.slug;"
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
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            let slug = parts[0]
            let count = Int(parts[1]) ?? 0
            counts[slug] = count
        }
        return counts
    }

    /// Queries the Postgres database for overall corpus, ingestion, and embedding statistics.
    func fetchCorpusStats() throws -> CorpusStats {
        try requireRunning()
        let password = try postgresPassword()

        let coreSql = """
        SELECT
            (SELECT count(*) FROM sources),
            (SELECT count(*) FROM documents),
            (SELECT count(*) FROM documents WHERE state = 'ok'),
            (SELECT count(*) FROM documents WHERE state <> 'ok'),
            (SELECT count(*) FROM chunks),
            (SELECT coalesce(sum(seen_count), 0) FROM (SELECT DISTINCT ON (source_id) seen_count FROM ingest_runs ORDER BY source_id, started_at DESC) r),
            (SELECT coalesce(sum(indexed_count), 0) FROM (SELECT DISTINCT ON (source_id) indexed_count FROM ingest_runs ORDER BY source_id, started_at DESC) r),
            (SELECT coalesce(sum(expected_elements), 0) FROM sources);
        """

        let (status, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                "-tAF\t", "-c", coreSql,
            ],
            environment: runtimeEnvironment(password: password)
        )
        guard status == 0 else {
            throw PostgresError.other("psql query failed: \(output)")
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "\t")
        guard parts.count >= 7 else {
            throw PostgresError.other("unexpected stats output: \(output)")
        }

        let sourcesCount = Int(parts[0]) ?? 0
        let docsCount = Int(parts[1]) ?? 0
        let docsOkCount = Int(parts[2]) ?? 0
        let docsFailedCount = Int(parts[3]) ?? 0
        let chunksCount = Int(parts[4]) ?? 0
        let seenCount = Int(parts[5]) ?? 0
        let indexedCount = Int(parts[6]) ?? 0
        let totalExpected = parts.count >= 8 ? (Int(parts[7]) ?? 0) : 0

        let models = (try? listRegisteredModels()) ?? []
        var modelStats: [CorpusStats.ModelEmbeddingStats] = []
        var totalEmbedded = 0
        var foundDefault = false

        for model in models {
            guard model.tableName.range(of: "^emb_[a-z0-9_]+$", options: .regularExpression) != nil else { continue }
            let countSql = "SELECT count(*) FROM \(model.tableName);"
            let (mStatus, mOutput) = ProcessRunner.runSync(
                executable: Paths.postgresTool("psql"),
                arguments: [
                    "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", databaseName,
                    "-tAF\t", "-c", countSql,
                ],
                environment: runtimeEnvironment(password: password)
            )
            let count = (mStatus == 0) ? (Int(mOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0
            modelStats.append(CorpusStats.ModelEmbeddingStats(
                slug: model.slug,
                tableName: model.tableName,
                isDefault: model.isDefault,
                embeddedCount: count
            ))
            if model.isDefault {
                totalEmbedded = count
                foundDefault = true
            }
        }

        if !foundDefault, let first = modelStats.first {
            totalEmbedded = first.embeddedCount
        }

        return CorpusStats(
            sourcesCount: sourcesCount,
            documentsCount: docsCount,
            documentsOkCount: docsOkCount,
            documentsFailedCount: docsFailedCount,
            totalChunks: chunksCount,
            embeddedChunks: totalEmbedded,
            totalSeenFiles: seenCount,
            totalIndexedFiles: indexedCount,
            totalExpectedElements: totalExpected,
            modelStats: modelStats,
            lastUpdated: Date()
        )
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func requireRunning() throws {
        guard status == .running || status == .needsMigration else {
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
    private static var inMemoryPassword: String?

    static func load() throws -> String? {
        if isRunningInTestEnvironment {
            return inMemoryPassword
        }
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
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw PostgresError.other("could not read Postgres password from Keychain (OSStatus \(status))")
        }
        return password
    }

    static func save(_ password: String) throws {
        if isRunningInTestEnvironment {
            inMemoryPassword = password
            return
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw PostgresError.other("could not save Postgres password in Keychain (OSStatus \(updateStatus))")
        }

        var newItem = query
        for (key, value) in attributes {
            newItem[key] = value
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
