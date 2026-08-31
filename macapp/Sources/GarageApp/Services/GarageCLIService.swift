import Foundation

/// Result of a completed `garage` CLI invocation.
struct GarageCommandResult {
    let exitCode: Int32
    let lines: [LogLine]

    var succeeded: Bool { exitCode == 0 }
}

/// Runs a category of `garage` CLI subcommands against the app-managed Postgres
/// instance. Each service has its own process state and rolling log.
@MainActor
final class GarageCLIService: ObservableObject {
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var isRunning = false

    private let postgres: PostgresService
    private let commandLabel: String
    private let maxLogLines = 4000

    init(postgres: PostgresService, commandLabel: String = "garage CLI") {
        self.postgres = postgres
        self.commandLabel = commandLabel
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    var cliAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path)
    }

    /// Runs `garage <arguments>`, streaming output into `logs`, and returns
    /// once the process exits.
    @discardableResult
    func run(_ arguments: [String]) async -> GarageCommandResult {
        guard !isRunning else {
            let line = LogLine(
                stream: .stderr,
                text: "\(commandLabel) is already running",
                source: commandLabel
            )
            appendLog(line)
            return GarageCommandResult(exitCode: -1, lines: [line])
        }

        guard cliAvailable else {
            let line = LogLine(
                stream: .stderr,
                text: "garage CLI not found at \(Paths.garageCLI.path)",
                source: commandLabel
            )
            appendLog(line)
            return GarageCommandResult(exitCode: -1, lines: [line])
        }

        isRunning = true
        defer { isRunning = false }

        var collected: [LogLine] = []
        let runner = ProcessRunner()
        let process: Process
        do {
            process = try runner.run(
                executable: Paths.garageCLI,
                arguments: arguments,
                environment: try environment(),
                currentDirectory: Paths.garageWorkingDirectory,
                source: commandLabel
            ) { [weak self] line in
                self?.appendLog(line)
                collected.append(line)
            }
        } catch {
            let line = LogLine(
                stream: .stderr,
                text: "failed to launch garage: \(error.localizedDescription)",
                source: commandLabel
            )
            appendLog(line)
            return GarageCommandResult(exitCode: -1, lines: [line])
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                DispatchQueue.main.async {
                    continuation.resume(returning: GarageCommandResult(exitCode: proc.terminationStatus, lines: collected))
                }
            }
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
}
