import Foundation
import Combine

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

    var connectionURL: String {
        "postgresql+psycopg://localhost:\(port)/\(databaseName)"
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

        let (status, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("initdb"),
            arguments: [
                "-D", Paths.pgDataDir.path,
                "-U", NSUserName(),
                "-E", "UTF8",
                "--auth=trust",
                "--no-instructions",
            ],
            environment: runtimeEnvironment()
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

        try await ensureDatabaseExists()
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

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
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

    private func ensureDatabaseExists() async throws {
        let (checkStatus, output) = ProcessRunner.runSync(
            executable: Paths.postgresTool("psql"),
            arguments: [
                "-h", "localhost", "-p", String(port), "-U", NSUserName(), "-d", "postgres",
                "-tAc", "SELECT 1 FROM pg_database WHERE datname = '\(databaseName)'",
            ]
        )
        guard checkStatus == 0 else {
            throw PostgresError.other("could not query pg_database: \(output)")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return
        }
        let (createStatus, createOutput) = ProcessRunner.runSync(
            executable: Paths.postgresTool("createdb"),
            arguments: ["-h", "localhost", "-p", String(port), "-U", NSUserName(), databaseName]
        )
        guard createStatus == 0 else {
            throw PostgresError.other("createdb failed: \(createOutput)")
        }
        appendLog(LogLine(stream: .stdout, text: "created database \(databaseName)", source: "postgres"))
    }

    /// Environment postgres needs to find its own dylibs and pgvector's shared
    /// object when running from a relocated (vendored) bundle.
    private func runtimeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = Paths.postgresLibDir.path
        // Without this, postgres fails at startup on macOS with "FATAL:
        // postmaster became multithreaded during startup" — some locale
        // initialization on this platform spins up threads before postgres's
        // fork-safety check runs. Confirmed via direct testing; the postgres
        // HINT suggesting LC_ALL is correct.
        env["LC_ALL"] = "C"
        return env
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
