import Foundation

enum GarageMCPStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

enum GarageMCPError: LocalizedError {
    case cliNotFound
    case startupTimeout
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "garage CLI not found at \(Paths.garageCLI.path)"
        case .startupTimeout:
            "garage-mcp did not become ready within 10 seconds"
        case .launchFailed(let message):
            "failed to launch garage-mcp: \(message)"
        }
    }
}

/// Owns the app-managed, loopback-only HTTP `garage-mcp` server.
@MainActor
final class GarageMCPService: ObservableObject {
    @Published private(set) var status: GarageMCPStatus = .stopped
    @Published private(set) var logs: [LogLine] = []

    let host = "127.0.0.1"
    let port = 8787
    let path = "/mcp"

    private let postgres: PostgresService
    private let runner = ProcessRunner()
    private let maxLogLines = 4000
    private var isStopping = false

    init(postgres: PostgresService) {
        self.postgres = postgres
    }

    var endpoint: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    func start() async throws {
        guard status == .stopped || isFailed else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            status = .failed(GarageMCPError.cliNotFound.localizedDescription)
            throw GarageMCPError.cliNotFound
        }

        status = .starting
        isStopping = false
        do {
            let process = try runner.run(
                executable: Paths.garageCLI,
                arguments: [
                    "mcp-serve",
                    "--http",
                    "--host", host,
                    "--port", String(port),
                    "--path", path,
                ],
                environment: try environment(),
                currentDirectory: Paths.garageWorkingDirectory,
                source: "garage-mcp"
            ) { [weak self] line in
                self?.appendLog(line)
            }
            process.terminationHandler = { [weak self] process in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.status = self.isStopping
                        ? .stopped
                        : .failed("garage-mcp exited with status \(process.terminationStatus)")
                }
            }
        } catch {
            let launchError = GarageMCPError.launchFailed(error.localizedDescription)
            status = .failed(launchError.localizedDescription)
            throw launchError
        }

        guard await waitUntilReady(timeout: 10) else {
            runner.terminate()
            status = .failed(GarageMCPError.startupTimeout.localizedDescription)
            throw GarageMCPError.startupTimeout
        }
        status = .running
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        isStopping = true
        runner.terminate()
        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        status = .stopped
    }

    func terminateImmediately() {
        isStopping = true
        runner.terminate()
    }

    private var isFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    private func environment() throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GARAGE_DATABASE_URL"] = try postgres.connectionURL()
        if let lmStudioToken = try LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }
        return env
    }

    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard runner.isRunning else { return false }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 1
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if response is HTTPURLResponse {
                    return true
                }
            } catch {
                // The server may still be starting; retry until the timeout.
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
