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
    nonisolated static let defaultPort = 8787
    nonisolated static let portDefaultsKey = "garage.mcp.port"

    @Published private(set) var status: GarageMCPStatus = .stopped
    @Published private(set) var logs: [LogLine] = []
    @Published var port: Int {
        didSet {
            defaults.set(port, forKey: Self.portDefaultsKey)
        }
    }

    let host = "127.0.0.1"
    let path = "/mcp"

    private let postgres: PostgresService
    private let runner: ProcessRunner
    private let defaults: UserDefaults
    private let maxLogLines = 4000
    private var isStopping = false

    init(
        postgres: PostgresService,
        port: Int? = nil,
        runner: ProcessRunner = ProcessRunner(),
        defaults: UserDefaults = .standard
    ) {
        self.postgres = postgres
        self.runner = runner
        self.defaults = defaults
        if let port {
            self.port = port
        } else {
            let savedPort = defaults.integer(forKey: Self.portDefaultsKey)
            self.port = (1...65535).contains(savedPort) ? savedPort : Self.defaultPort
        }
    }

    var endpoint: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    nonisolated static func randomPort(excluding: Set<Int> = []) -> Int {
        var candidate: Int
        repeat {
            candidate = Int.random(in: 1024...65535)
        } while excluding.contains(candidate)
        return candidate
    }

    @discardableResult
    func selectRandomPort() -> Int {
        let newPort = Self.randomPort(excluding: [port])
        self.port = newPort
        return newPort
    }

    func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws {
        guard status == .stopped || isFailed else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            status = .failed(GarageMCPError.cliNotFound.localizedDescription)
            throw GarageMCPError.cliNotFound
        }

        var attemptsLeft = max(1, maxAttempts)
        var triedPorts: Set<Int> = []

        while attemptsLeft > 0 {
            let currentPort = port
            triedPorts.insert(currentPort)
            status = .starting
            isStopping = false

            var processInstance: Process?
            do {
                let process = try runner.run(
                    executable: Paths.garageCLI,
                    arguments: [
                        "mcp-serve",
                        "--http",
                        "--host", host,
                        "--port", String(currentPort),
                        "--path", path,
                    ],
                    environment: try environment(),
                    currentDirectory: Paths.garageWorkingDirectory,
                    source: "garage-mcp"
                ) { [weak self] line in
                    self?.appendLog(line)
                }
                processInstance = process
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

            let ready = await waitUntilReady(timeout: readyTimeout)
            if ready {
                status = .running
                return
            }

            // Startup / loading failed on currentPort
            attemptsLeft -= 1
            processInstance?.terminationHandler = nil
            runner.terminate()
            for _ in 0..<20 where runner.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            if attemptsLeft > 0 {
                let newPort = Self.randomPort(excluding: triedPorts)
                appendLog(LogLine(
                    stream: .stderr,
                    text: "Failed to load garage-mcp on port \(currentPort); selecting random port \(newPort)…",
                    source: "garage-mcp"
                ))
                self.port = newPort
            } else {
                status = .failed(GarageMCPError.startupTimeout.localizedDescription)
                throw GarageMCPError.startupTimeout
            }
        }
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
