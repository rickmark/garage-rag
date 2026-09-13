import Foundation
import IngestClient
import OSLog

private let logger = Logger(subsystem: "me.rickmark.garage", category: "IngestService")

/// Execution strategy for document ingestion.
public enum IngestExecutionMode: String, CaseIterable, Identifiable, Sendable {
    case xpcService = "xpc"
    case inProcess = "in_process"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .xpcService: return "Out-of-Process (XPC Helper)"
        case .inProcess: return "In-Process (Embedded)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .xpcService: return "XPC Helper"
        case .inProcess: return "In-Process"
        }
    }

    public var modeDescription: String {
        switch self {
        case .xpcService:
            return "Runs Python ingestion in a dedicated multi-threaded background process (GarageIngestXPCService) with crash isolation."
        case .inProcess:
            return "Runs Python ingestion directly inside the main application process."
        }
    }
}

/// Observable service that coordinates ingestion through the XPC service or in-process engine,
/// maintaining real-time progress state, per-source metrics, and logs for the UI.
@MainActor
public final class IngestService: ObservableObject {
    @Published public var executionMode: IngestExecutionMode {
        didSet {
            UserDefaults.standard.set(executionMode.rawValue, forKey: "garage.ingest.executionMode")
        }
    }

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var isCancelling: Bool = false
    @Published public private(set) var activeMode: IngestExecutionMode? = nil
    @Published public private(set) var currentSource: String? = nil
    @Published public private(set) var latestProgress: IngestProgressUpdate? = nil
    @Published public private(set) var progressBySource: [String: IngestProgressUpdate] = [:]
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var lastSuccess: String? = nil
    @Published public private(set) var logs: [LogLine] = []
    @Published public private(set) var startedAt: Date? = nil

    public let xpcClient: IngestClient
    public let inProcessClient: IngestClient
    private let maxLogLines = 4000
    private var activeActivity: NSObjectProtocol? = nil

    public init(
        client: IngestClient = IngestClient(),
        inProcessClient: IngestClient = IngestClient(inProcessEngine: IngestEngine.shared)
    ) {
        let savedMode = UserDefaults.standard.string(forKey: "garage.ingest.executionMode")
        self.executionMode = savedMode.flatMap(IngestExecutionMode.init) ?? .xpcService
        self.xpcClient = client
        self.inProcessClient = inProcessClient
    }

    public var client: IngestClient {
        executionMode == .inProcess ? inProcessClient : xpcClient
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

    public func handleProgress(_ progress: IngestProgressUpdate, sourceLabel: String = "Ingest") {
        self.latestProgress = progress
        self.progressBySource[progress.source] = progress
        if self.currentSource == nil || self.currentSource == "*" {
            self.currentSource = progress.source
        }

        logger.debug("IngestService progress (\(sourceLabel, privacy: .public)): phase=\(progress.phase, privacy: .public), msg=\(progress.message, privacy: .public)")

        if !progress.message.isEmpty {
            let stream: LogLine.Stream = progress.isError ? .stderr : .stdout
            let line = LogLine(
                stream: stream,
                text: progress.message,
                source: sourceLabel
            )
            appendLog(line)
        }
    }

    /// Cancels any active ingestion run.
    @discardableResult
    public func cancel() async -> Bool {
        guard isRunning else { return false }
        isCancelling = true
        let label = activeMode == .inProcess ? "Ingest (In-Process)" : "Ingest (XPC)"
        logger.info("IngestService: requesting cancel for '\(self.currentSource ?? "source", privacy: .public)' in mode \(label, privacy: .public)")
        let line = LogLine(
            stream: .stderr,
            text: "Cancelling ingestion for '\(currentSource ?? "source")'...",
            source: label
        )
        appendLog(line)

        let targetClient = activeMode == .inProcess ? inProcessClient : xpcClient
        do {
            let success = try await targetClient.cancelIngest()
            logger.info("IngestService: cancel signal result: \(success)")
            return success
        } catch {
            let errorMsg = "Failed to send cancel signal: \(error.localizedDescription)"
            logger.error("IngestService: cancel signal failed: \(error.localizedDescription, privacy: .public)")
            lastError = errorMsg
            let errLine = LogLine(stream: .stderr, text: errorMsg, source: label)
            appendLog(errLine)
            return false
        }
    }

    /// Performs ingestion for the given source slug with options and execution mode, streaming progress back to the UI.
    @discardableResult
    public func ingest(
        slug: String,
        options: IngestOptions = .default,
        mode: IngestExecutionMode? = nil
    ) async -> IngestResult {
        let targetMode = mode ?? executionMode
        let commandLabel = targetMode == .inProcess ? "Ingest (In-Process)" : "Ingest (XPC)"

        guard !isRunning else {
            let msg = "Ingestion is already running for \(currentSource ?? "another source")"
            logger.warning("IngestService: \(msg, privacy: .public)")
            let line = LogLine(stream: .stderr, text: msg, source: commandLabel)
            appendLog(line)
            lastError = msg
            return IngestResult(succeeded: false, message: msg)
        }

        isRunning = true
        activeMode = targetMode
        currentSource = slug
        startedAt = Date()
        lastError = nil
        lastSuccess = nil

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Garage document ingestion for \(slug) (\(targetMode.shortTitle))"
        )
        self.activeActivity = activity

        let startMsg = "Starting ingestion [\(targetMode.title)] for source '\(slug)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)))..."
        logger.info("IngestService: \(startMsg, privacy: .public)")
        let startLine = LogLine(
            stream: .stdout,
            text: startMsg,
            source: commandLabel
        )
        appendLog(startLine)

        defer {
            isRunning = false
            isCancelling = false
            activeMode = nil
            currentSource = nil
            startedAt = nil
            if let act = self.activeActivity {
                ProcessInfo.processInfo.endActivity(act)
                self.activeActivity = nil
            }
        }

        let selectedClient = targetMode == .inProcess ? inProcessClient : xpcClient
        let effectiveOptions: IngestOptions
        if options.grpcPort == nil {
            effectiveOptions = IngestOptions(
                includeCode: options.includeCode,
                limit: options.limit,
                force: options.force,
                grpcHost: options.grpcHost ?? "127.0.0.1",
                grpcPort: 50051
            )
        } else {
            effectiveOptions = options
        }

        do {
            let result = try await selectedClient.ingest(slug: slug, options: effectiveOptions) { [weak self] progress in
                Task { @MainActor in
                    self?.handleProgress(progress, sourceLabel: commandLabel)
                }
            }

            if result.succeeded {
                let successMsg = result.message ?? "Ingestion finished successfully for \(slug) [\(targetMode.shortTitle)]"
                logger.info("IngestService: \(successMsg, privacy: .public)")
                lastSuccess = successMsg
                let line = LogLine(stream: .stdout, text: successMsg, source: commandLabel)
                appendLog(line)
            } else {
                let errorMsg = result.message ?? "Ingestion failed for \(slug) [\(targetMode.shortTitle)]"
                logger.error("IngestService: \(errorMsg, privacy: .public)")
                lastError = errorMsg
                let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                appendLog(line)
            }

            return result
        } catch {
            let errorMsg = "Ingestion error for \(slug) [\(targetMode.shortTitle)]: \(error.localizedDescription)"
            logger.error("IngestService: \(errorMsg, privacy: .public)")
            lastError = errorMsg
            let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
            appendLog(line)
            return IngestResult(succeeded: false, message: errorMsg)
        }
    }
}
