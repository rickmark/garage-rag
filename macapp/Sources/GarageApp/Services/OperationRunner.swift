import Foundation

/// Outcome of one `OperationRunner.run` call.
struct OperationResult {
    let succeeded: Bool
    /// What the operation reported on success, or the error message on failure.
    let output: String
}

/// Runs one category of app operations (general commands, embedding backfill, fact
/// distillation) as gRPC calls on `GarageGRPCService`, one at a time, with its own
/// busy flag and rolling log. The app used to spawn `garage <subcommand>` for these;
/// each category keeps a runner so a long backfill never blocks an ordinary command.
@MainActor
final class OperationRunner: ObservableObject {
    @Published private(set) var logs: [LogLine] = []
    @Published var isRunning = false

    let label: String
    private let maxLogLines = 4000
    private var currentTask: Task<String, Error>?

    init(label: String = "garage") {
        self.label = label
    }

    func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        appendLog(LogLine(stream: stream, text: text, source: label))
    }

    func clearLogs() {
        logs.removeAll()
    }

    /// Cancels the running operation. Cancelling a streaming call ends it on the
    /// server too, which stops the work at its next progress step.
    func cancel() {
        guard isRunning, let currentTask else { return }
        appendLog("Cancelling \(label)...", stream: .stderr)
        currentTask.cancel()
    }

    /// Runs `operation`, logging the text it returns (or its error), and returns once
    /// it finishes. Streaming operations log their own progress through the runner
    /// they are handed. Refuses to start while another operation is running.
    @discardableResult
    func run(_ operation: @escaping @MainActor (OperationRunner) async throws -> String) async -> OperationResult {
        guard !isRunning else {
            let message = "\(label) is already running"
            appendLog(message, stream: .stderr)
            return OperationResult(succeeded: false, output: message)
        }

        isRunning = true
        let task = Task { @MainActor in
            try await operation(self)
        }
        currentTask = task
        defer {
            currentTask = nil
            isRunning = false
        }

        do {
            let output = try await task.value
            for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
                appendLog(String(line))
            }
            return OperationResult(succeeded: true, output: output)
        } catch let error where error is CancellationError || task.isCancelled {
            let message = "\(label) cancelled"
            appendLog(message, stream: .stderr)
            return OperationResult(succeeded: false, output: message)
        } catch {
            let message = error.localizedDescription
            appendLog(message, stream: .stderr)
            return OperationResult(succeeded: false, output: message)
        }
    }
}
