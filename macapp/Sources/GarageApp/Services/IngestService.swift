import Foundation
import IngestClient
import OSLog

private let logger = Logger(subsystem: "me.rickmark.garage", category: "IngestService")

/// Execution strategy for document ingestion.
enum IngestExecutionMode: String, CaseIterable, Identifiable, Sendable {
    case xpcService = "xpc"
    case inProcess = "in_process"
    case cliProcess = "cli_process"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xpcService: return "Out-of-Process (XPC Helper)"
        case .inProcess: return "In-Process (Embedded)"
        case .cliProcess: return "Out-of-Process (`garage ingest` CLI)"
        }
    }

    var shortTitle: String {
        switch self {
        case .xpcService: return "XPC Helper"
        case .inProcess: return "In-Process"
        case .cliProcess: return "CLI Process"
        }
    }

    var modeDescription: String {
        switch self {
        case .xpcService:
            return "Runs Python ingestion in a dedicated multi-threaded background process (GarageIngestXPCService) with crash isolation."
        case .inProcess:
            return "Runs Python ingestion directly inside the main application process."
        case .cliProcess:
            return "Runs document ingestion out-of-process by executing the standalone `garage ingest` CLI process."
        }
    }
}

/// Observable service that coordinates ingestion through the XPC service or in-process engine,
/// maintaining real-time progress state, per-source metrics, and logs for the UI.
@MainActor
final class IngestService: ObservableObject {
    @Published var executionMode: IngestExecutionMode {
        didSet {
            UserDefaults.standard.set(executionMode.rawValue, forKey: "garage.ingest.executionMode")
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isCancelling: Bool = false
    @Published private(set) var activeMode: IngestExecutionMode? = nil
    @Published private(set) var currentSource: String? = nil
    @Published private(set) var latestProgress: IngestProgressUpdate? = nil
    @Published private(set) var progressBySource: [String: IngestProgressUpdate] = [:]
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastSuccess: String? = nil
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var startedAt: Date? = nil

    let xpcClient: IngestClient
    let inProcessClient: IngestClient
    let postgres: PostgresService?
    private var cliRunner: ProcessRunner?
    private var cliProcess: Process?
    private let maxLogLines = 4000
    private var activeActivity: NSObjectProtocol? = nil

    init(
        client: IngestClient = IngestClient(),
        inProcessClient: IngestClient = IngestClient(inProcessEngine: IngestEngine.shared),
        postgres: PostgresService? = nil
    ) {
        let savedMode = UserDefaults.standard.string(forKey: "garage.ingest.executionMode")
        self.executionMode = savedMode.flatMap(IngestExecutionMode.init) ?? .xpcService
        self.xpcClient = client
        self.inProcessClient = inProcessClient
        self.postgres = postgres
    }

    var client: IngestClient {
        executionMode == .inProcess ? inProcessClient : xpcClient
    }

    func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        appendLog(LogLine(stream: stream, text: text, source: "Ingest"))
    }

    func clearLogs() {
        logs.removeAll()
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
    }

    func handleProgress(_ progress: IngestProgressUpdate, sourceLabel: String = "Ingest") {
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
    func cancel() async -> Bool {
        guard isRunning else { return false }
        isCancelling = true
        let label: String
        switch activeMode {
        case .inProcess: label = "Ingest (In-Process)"
        case .cliProcess: label = "Ingest (CLI)"
        default: label = "Ingest (XPC)"
        }
        logger.info("IngestService: requesting cancel for '\(self.currentSource ?? "source", privacy: .public)' in mode \(label, privacy: .public)")
        let line = LogLine(
            stream: .stderr,
            text: "Cancelling ingestion for '\(currentSource ?? "source")'...",
            source: label
        )
        appendLog(line)

        if activeMode == .cliProcess {
            cliRunner?.terminate()
            cliProcess?.terminate()
            return true
        }

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
    func ingest(
        slug: String,
        options: IngestOptions = .default,
        mode: IngestExecutionMode? = nil
    ) async -> IngestResult {
        let targetMode = mode ?? executionMode
        let commandLabel: String
        switch targetMode {
        case .inProcess: commandLabel = "Ingest (In-Process)"
        case .cliProcess: commandLabel = "Ingest (CLI)"
        case .xpcService: commandLabel = "Ingest (XPC)"
        }

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

        if targetMode == .cliProcess {
            return await runCliIngest(slug: slug, options: options, commandLabel: commandLabel)
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

    private func runCliIngest(
        slug: String,
        options: IngestOptions,
        commandLabel: String
    ) async -> IngestResult {
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            let msg = "garage CLI executable not found at \(Paths.garageCLI.path)"
            logger.error("\(msg, privacy: .public)")
            let line = LogLine(stream: .stderr, text: msg, source: commandLabel)
            appendLog(line)
            lastError = msg
            return IngestResult(succeeded: false, message: msg)
        }

        var args = ["ingest", "--source", slug]
        if options.includeCode {
            args.append("--include-code")
        }
        if options.force {
            args.append("--force")
        }
        if let limit = options.limit {
            args.append(contentsOf: ["--limit", "\(limit)"])
        }

        let runner = ProcessRunner()
        self.cliRunner = runner

        defer {
            self.cliRunner = nil
            self.cliProcess = nil
        }

        var env = ProcessInfo.processInfo.environment
        if let postgres = self.postgres, let dbURL = try? postgres.connectionURL() {
            env["GARAGE_DATABASE_URL"] = dbURL
        }
        if let lmStudioToken = try? LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }

        let process: Process
        do {
            process = try runner.run(
                executable: Paths.garageCLI,
                arguments: args,
                environment: env,
                currentDirectory: Paths.garageWorkingDirectory,
                source: commandLabel
            ) { [weak self] line in
                self?.appendLog(line)
            }
            self.cliProcess = process
        } catch {
            let errorMsg = "Failed to launch garage ingest CLI: \(error.localizedDescription)"
            logger.error("\(errorMsg, privacy: .public)")
            let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
            appendLog(line)
            lastError = errorMsg
            return IngestResult(succeeded: false, message: errorMsg)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    let exitCode = proc.terminationStatus
                    let succeeded = exitCode == 0
                    let resultMsg = succeeded
                        ? "Ingest completed successfully via CLI process (exit code: \(exitCode))"
                        : "Ingest failed via CLI process (exit code: \(exitCode))"
                    if succeeded {
                        self?.lastSuccess = resultMsg
                    } else {
                        self?.lastError = resultMsg
                    }
                    continuation.resume(returning: IngestResult(succeeded: succeeded, message: resultMsg))
                }
            }
        }
    }
}
