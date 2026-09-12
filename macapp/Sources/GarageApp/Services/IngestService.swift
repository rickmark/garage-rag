import Foundation
import IngestClient

/// Observable service that coordinates ingestion through the XPC service and maintains
/// real-time progress state, per-source metrics, and logs for the UI.
@MainActor
public final class IngestService: ObservableObject {
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var currentSource: String? = nil
    @Published public private(set) var latestProgress: IngestProgressUpdate? = nil
    @Published public private(set) var progressBySource: [String: IngestProgressUpdate] = [:]
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var lastSuccess: String? = nil
    @Published public private(set) var logs: [LogLine] = []

    public let client: IngestClient
    private let commandLabel: String = "Ingest XPC"
    private let maxLogLines = 4000

    public init(client: IngestClient = IngestClient()) {
        self.client = client
    }

    public func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    public func clearMessages() {
        lastError = nil
        lastSuccess = nil
    }

    public func handleProgress(_ progress: IngestProgressUpdate) {
        self.latestProgress = progress
        self.progressBySource[progress.source] = progress

        if !progress.message.isEmpty {
            let stream: LogLine.Stream = progress.isError ? .stderr : .stdout
            let line = LogLine(
                stream: stream,
                text: progress.message,
                source: commandLabel
            )
            appendLog(line)
        }
    }

    /// Performs ingestion for the given source slug with options, streaming progress back to the UI.
    @discardableResult
    public func ingest(slug: String, options: IngestOptions = .default) async -> IngestResult {
        guard !isRunning else {
            let msg = "Ingestion is already running for \(currentSource ?? "another source")"
            let line = LogLine(stream: .stderr, text: msg, source: commandLabel)
            appendLog(line)
            lastError = msg
            return IngestResult(succeeded: false, message: msg)
        }

        isRunning = true
        currentSource = slug
        lastError = nil
        lastSuccess = nil

        let startLine = LogLine(
            stream: .stdout,
            text: "Starting ingestion for source '\(slug)' (includeCode: \(options.includeCode), force: \(options.force))...",
            source: commandLabel
        )
        appendLog(startLine)

        do {
            let result = try await client.ingest(slug: slug, options: options) { [weak self] progress in
                Task { @MainActor in
                    self?.handleProgress(progress)
                }
            }

            isRunning = false
            currentSource = nil

            if result.succeeded {
                let successMsg = result.message ?? "Ingestion finished successfully for \(slug)"
                lastSuccess = successMsg
                let line = LogLine(stream: .stdout, text: successMsg, source: commandLabel)
                appendLog(line)
            } else {
                let errorMsg = result.message ?? "Ingestion failed for \(slug)"
                lastError = errorMsg
                let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                appendLog(line)
            }

            return result
        } catch {
            isRunning = false
            currentSource = nil
            let errorMsg = "Ingestion error for \(slug): \(error.localizedDescription)"
            lastError = errorMsg
            let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
            appendLog(line)
            return IngestResult(succeeded: false, message: errorMsg)
        }
    }
}
