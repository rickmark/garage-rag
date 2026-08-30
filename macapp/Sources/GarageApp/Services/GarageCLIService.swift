import Foundation

/// Result of a completed `garage` CLI invocation.
struct GarageCommandResult {
    let exitCode: Int32
    let lines: [LogLine]

    var succeeded: Bool { exitCode == 0 }
}

/// Runs `garage` CLI subcommands against the app-managed Postgres instance.
/// Each call is a fresh process; there is no long-running `garage` daemon.
@MainActor
final class GarageCLIService: ObservableObject {
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var isRunning = false

    private let postgres: PostgresService
    private let maxLogLines = 4000

    init(postgres: PostgresService) {
        self.postgres = postgres
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
        guard cliAvailable else {
            let line = LogLine(
                stream: .stderr,
                text: "garage CLI not found at \(Paths.garageCLI.path)",
                source: "garage"
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
                environment: environment(),
                currentDirectory: Paths.garageWorkingDirectory,
                source: "garage \(arguments.first ?? "")"
            ) { [weak self] line in
                self?.appendLog(line)
                collected.append(line)
            }
        } catch {
            let line = LogLine(stream: .stderr, text: "failed to launch garage: \(error.localizedDescription)", source: "garage")
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

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GARAGE_DATABASE_URL"] = postgres.connectionURL
        return env
    }
}
