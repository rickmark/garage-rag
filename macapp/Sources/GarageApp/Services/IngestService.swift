import Foundation
import IngestClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "IngestService")

/// Thread-safe buffer for batching background ingest logs and progress updates before dispatching to MainActor.
private final class IngestBatchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLogs: [LogLine] = []
    private var pendingProgress: [IngestProgressUpdate] = []

    func appendLog(_ line: LogLine) {
        lock.lock()
        pendingLogs.append(line)
        lock.unlock()
    }

    func appendProgress(_ progress: IngestProgressUpdate) {
        lock.lock()
        pendingProgress.append(progress)
        lock.unlock()
    }

    func drain() -> (logs: [LogLine], progress: [IngestProgressUpdate]) {
        lock.lock()
        let logs = pendingLogs
        let progress = pendingProgress
        pendingLogs.removeAll(keepingCapacity: true)
        pendingProgress.removeAll(keepingCapacity: true)
        lock.unlock()
        return (logs, progress)
    }
}

/// Execution strategy for document ingestion (XPC service).
enum IngestExecutionMode: String, CaseIterable, Identifiable, Sendable {
    case xpcService = "xpc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .xpcService: return "Out-of-Process (XPC Helper)"
        }
    }

    var shortTitle: String {
        switch self {
        case .xpcService: return "XPC Helper"
        }
    }

    var modeDescription: String {
        switch self {
        case .xpcService:
            return "Runs Python ingestion in a dedicated multi-threaded background process (GarageIngestXPCService) with crash isolation."
        }
    }
}

/// Observable service that coordinates ingestion through the XPC service or CLI process,
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
    @Published private(set) var pendingSources: Set<String> = []
    @Published private(set) var latestProgress: IngestProgressUpdate? = nil
    @Published private(set) var progressBySource: [String: IngestProgressUpdate] = [:]
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastSuccess: String? = nil
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var startedAt: Date? = nil

    let xpcClient: IngestClient
    let postgres: PostgresService?
    private let maxLogLines = 4000
    private var activeActivity: NSObjectProtocol? = nil
    private var osLogMonitorTask: Task<Void, Never>? = nil
    private var seenLogKeys: Set<String> = []
    private var seenLogKeyQueue: [String] = []
    private let maxSeenKeys = 2000

    init(
        client: IngestClient = IngestClient(),
        postgres: PostgresService? = nil,
        startMonitoring: Bool = true
    ) {
        let savedMode = UserDefaults.standard.string(forKey: "garage.ingest.executionMode")
        self.executionMode = savedMode.flatMap(IngestExecutionMode.init) ?? .xpcService
        self.xpcClient = client
        self.postgres = postgres
        if startMonitoring {
            self.startOSLogMonitoring(since: Date().addingTimeInterval(-300))
        }
    }

    var client: IngestClient {
        xpcClient
    }

    func appendLog(_ line: LogLine) {
        appendLogs([line])
    }

    func appendLogs(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }

        var accepted: [LogLine] = []
        accepted.reserveCapacity(lines.count)

        for line in lines {
            let textTrimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !textTrimmed.isEmpty else { continue }

            let timeBucket = Int(line.date.timeIntervalSince1970)
            let key = "\(textTrimmed)|\(timeBucket)"

            if seenLogKeys.contains(key) {
                continue
            }
            seenLogKeys.insert(key)
            seenLogKeyQueue.append(key)
            accepted.append(line)
        }

        if seenLogKeyQueue.count > maxSeenKeys {
            let overflow = seenLogKeyQueue.count - maxSeenKeys
            for removed in seenLogKeyQueue.prefix(overflow) {
                seenLogKeys.remove(removed)
            }
            seenLogKeyQueue.removeFirst(overflow)
        }

        guard !accepted.isEmpty else { return }

        // Single @Published mutation for the whole batch instead of one per line - each mutation triggers a
        // reflection-based Combine objectWillChange publish, which is what stalls the main thread when a burst
        // (e.g. Dropbox source scans) drains hundreds or thousands of lines into one appendLogs call.
        logs.append(contentsOf: accepted)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func appendLog(_ text: String, stream: LogLine.Stream = .stdout) {
        appendLog(LogLine(stream: stream, text: text, source: "Ingest"))
    }

    func clearLogs() {
        logs.removeAll()
        seenLogKeys.removeAll()
        seenLogKeyQueue.removeAll()
    }

    func clearMessages() {
        lastError = nil
        lastSuccess = nil
        latestProgress = nil
        progressBySource.removeAll()
    }

    func clearProgressBySource() {
        self.progressBySource.removeAll()
    }

    func setPendingSources(_ slugs: Set<String>) {
        self.pendingSources = slugs
    }

    func markSourceActive(_ slug: String) {
        self.pendingSources.remove(slug)
    }

    func clearPendingSources() {
        self.pendingSources.removeAll()
    }

    // MARK: - OSLogStore Monitoring

    private func isRelevantIngestLog(category: String, message: String, process: String) -> Bool {
        if category.localizedCaseInsensitiveContains("ingest") ||
            category == "GarageXPCOutputCapture" ||
            category == "IngestService" ||
            category == "IngestClient" ||
            category == "GarageIngestXPCService" ||
            process.localizedCaseInsensitiveContains("GarageIngest") ||
            message.hasPrefix("[Python]") {
            return true
        }
        return false
    }

    private func processOSLogEntry(_ entry: OSLogEntry) {
        guard let logEntry = entry as? OSLogEntryLog else { return }
        let category = logEntry.category
        let message = logEntry.composedMessage
        let process = logEntry.process

        guard isRelevantIngestLog(category: category, message: message, process: process) else { return }

        let stream: LogLine.Stream = (logEntry.level == .fault || logEntry.level == .error) ? .stderr : .stdout
        let level: LogLevel
        switch logEntry.level {
        case .fault, .error:
            level = .error
        case .info, .notice:
            level = .info
        case .debug:
            level = .debug
        default:
            level = .info
        }

        let sourceLabel: String
        if !category.isEmpty {
            sourceLabel = category
        } else if !process.isEmpty {
            sourceLabel = process
        } else {
            sourceLabel = "Ingest (OSLog)"
        }

        let line = LogLine(
            id: UUID(),
            date: logEntry.date,
            stream: stream,
            text: message,
            source: sourceLabel,
            level: level
        )
        appendLog(line)
    }

    func startOSLogMonitoring(since startDate: Date) {
        stopOSLogMonitoring()

        guard #available(macOS 12.0, *) else { return }
        osLogMonitorTask = Task { [weak self] in
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }

            var lastDate = startDate
            var lastPosition = store.position(date: startDate)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH 'me.rickmark.garage' OR process CONTAINS[c] 'GarageIngest'")

            while !Task.isCancelled {
                do {
                    let entries = try store.getEntries(at: lastPosition, matching: predicate)
                    var maxDate = lastDate
                    var collected: [OSLogEntry] = []

                    for entry in entries {
                        collected.append(entry)
                        if entry.date > maxDate {
                            maxDate = entry.date
                        }
                    }

                    if !collected.isEmpty {
                        await MainActor.run {
                            for entry in collected {
                                self?.processOSLogEntry(entry)
                            }
                        }
                    }

                    lastDate = maxDate
                    lastPosition = store.position(date: lastDate)
                } catch {
                    logger.debug("IngestService: OSLogStore polling error: \(error.localizedDescription, privacy: .public)")
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopOSLogMonitoring() {
        osLogMonitorTask?.cancel()
        osLogMonitorTask = nil
    }

    func drainOSLogs(since startDate: Date) {
        guard #available(macOS 12.0, *) else { return }
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let position = store.position(date: startDate)
        let predicate = NSPredicate(format: "subsystem BEGINSWITH 'me.rickmark.garage' OR process CONTAINS[c] 'GarageIngest'")
        if let entries = try? store.getEntries(at: position, matching: predicate) {
            for entry in entries {
                processOSLogEntry(entry)
            }
        }
    }

    public func fetchRecentLogsFromOSLogStore(timeWindow: TimeInterval = 300) {
        let startDate = Date().addingTimeInterval(-timeWindow)
        drainOSLogs(since: startDate)
    }

    func handleProgress(_ progress: IngestProgressUpdate, sourceLabel: String = "Ingest") {
        handleProgressBatch([progress], sourceLabel: sourceLabel)
    }

    func handleProgressBatch(_ updates: [IngestProgressUpdate], sourceLabel: String = "Ingest") {
        guard !updates.isEmpty else { return }
        var progressLogs: [LogLine] = []
        var mergedProgressBySource = progressBySource
        var newCurrentSource: String? = nil

        for progress in updates {
            mergedProgressBySource[progress.source] = progress
            if newCurrentSource == nil && (self.currentSource == nil || self.currentSource == "*") {
                newCurrentSource = progress.source
            }

            logger.debug("IngestService progress (\(sourceLabel, privacy: .public)): phase=\(progress.phase, privacy: .public), msg=\(progress.message, privacy: .public)")

            if !progress.message.isEmpty {
                let stream: LogLine.Stream = progress.isError ? .stderr : .stdout
                let line = LogLine(
                    stream: stream,
                    text: progress.message,
                    source: sourceLabel
                )
                progressLogs.append(line)
            }
        }

        // Assign each @Published property once for the whole batch rather than once per update - see appendLogs
        // for why: bursty sources (e.g. Dropbox scans) can hand this hundreds of updates at a time.
        latestProgress = updates.last
        progressBySource = mergedProgressBySource
        if let newCurrentSource {
            currentSource = newCurrentSource
        }
        if !progressLogs.isEmpty {
            appendLogs(progressLogs)
        }
    }

    /// Cancels any active ingestion run.
    @discardableResult
    func cancel() async -> Bool {
        guard isRunning else { return false }
        isCancelling = true
        let label = "Ingest (XPC)"
        logger.info("IngestService: requesting cancel for '\(self.currentSource ?? "source", privacy: .public)'")
        let line = LogLine(
            stream: .stderr,
            text: "Cancelling ingestion for '\(currentSource ?? "source")'...",
            source: label
        )
        appendLog(line)

        do {
            let success = try await xpcClient.cancelIngest()
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

    /// Performs ingestion for the given source slug with options, streaming progress back to the UI.
    @discardableResult
    nonisolated func ingest(
        slug: String,
        options: IngestOptions = .default,
        mode: IngestExecutionMode? = nil
    ) async -> IngestResult {
        let commandLabel = "Ingest (XPC)"

        let prep = await MainActor.run { () -> (shouldProceed: Bool, errorResult: IngestResult?, runStartDate: Date, targetMode: IngestExecutionMode, dbURL: String?, lmToken: String?) in
            let targetMode = mode ?? self.executionMode

            guard !self.isRunning else {
                let msg = "Ingestion is already running for \(self.currentSource ?? "another source")"
                logger.warning("IngestService: \(msg, privacy: .public)")
                let line = LogLine(stream: .stderr, text: msg, source: commandLabel)
                self.appendLog(line)
                self.lastError = msg
                return (false, IngestResult(succeeded: false, message: msg), Date(), targetMode, nil, nil)
            }

            self.isRunning = true
            self.activeMode = targetMode
            self.currentSource = slug
            let runStartDate = Date()
            self.startedAt = runStartDate
            self.lastError = nil
            self.lastSuccess = nil

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
            self.appendLog(startLine)

            self.startOSLogMonitoring(since: runStartDate.addingTimeInterval(-1.0))

            var effectiveDatabaseURL = options.databaseUrl
            if effectiveDatabaseURL == nil, let postgres = self.postgres, let dbURL = try? postgres.connectionURL() {
                effectiveDatabaseURL = dbURL
            }
            var effectiveLMStudioToken = options.lmStudioApiToken
            if effectiveLMStudioToken == nil, let lmToken = try? LMStudioTokenStore.load() {
                effectiveLMStudioToken = lmToken
            }

            return (true, nil, runStartDate, targetMode, effectiveDatabaseURL, effectiveLMStudioToken)
        }

        guard prep.shouldProceed else {
            return prep.errorResult ?? IngestResult(succeeded: false, message: "Ingestion is already running")
        }

        let runStartDate = prep.runStartDate
        let targetMode = prep.targetMode
        let selectedClient = self.xpcClient

        let cleanup = { @MainActor [weak self] in
            guard let self = self else { return }
            self.stopOSLogMonitoring()
            self.drainOSLogs(since: runStartDate.addingTimeInterval(-1.0))
            self.isRunning = false
            self.isCancelling = false
            self.activeMode = nil
            self.currentSource = nil
            self.startedAt = nil
            if let act = self.activeActivity {
                ProcessInfo.processInfo.endActivity(act)
                self.activeActivity = nil
            }
        }

        let batchBuffer = IngestBatchBuffer()
        let batchFlushTask = Task { [weak self, batchBuffer] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let (logs, progressUpdates) = batchBuffer.drain()
                if !logs.isEmpty || !progressUpdates.isEmpty {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        if !logs.isEmpty {
                            self.appendLogs(logs)
                        }
                        if !progressUpdates.isEmpty {
                            self.handleProgressBatch(progressUpdates, sourceLabel: commandLabel)
                        }
                    }
                }
            }
        }

        defer {
            batchFlushTask.cancel()
            Task { @MainActor [weak self, batchBuffer] in
                let (remainingLogs, remainingProgress) = batchBuffer.drain()
                if let self = self {
                    if !remainingLogs.isEmpty {
                        self.appendLogs(remainingLogs)
                    }
                    if !remainingProgress.isEmpty {
                        self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                    }
                }
                if self?.isRunning == true {
                    cleanup()
                }
            }
        }

        let effectiveOptions = IngestOptions(
            includeCode: options.includeCode,
            limit: options.limit,
            force: options.force,
            grpcHost: options.grpcHost,
            grpcPort: options.grpcPort,
            extraArguments: options.extraArguments,
            databaseUrl: prep.dbURL,
            lmStudioApiToken: prep.lmToken
        )

        if let dbURL = prep.dbURL {
            _ = try? await selectedClient.setDatabaseURL(dbURL, lmStudioApiToken: prep.lmToken)
        }

        do {
            let result = try await selectedClient.ingest(
                slug: slug,
                options: effectiveOptions,
                onLog: { message, level in
                    let stream: LogLine.Stream = level >= 40 ? .stderr : .stdout
                    batchBuffer.appendLog(LogLine(stream: stream, text: message, source: commandLabel))
                },
                onProgress: { progress in
                    batchBuffer.appendProgress(progress)
                }
            )

            batchFlushTask.cancel()
            let (remainingLogs, remainingProgress) = batchBuffer.drain()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if !remainingLogs.isEmpty {
                    self.appendLogs(remainingLogs)
                }
                if !remainingProgress.isEmpty {
                    self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                }
                if result.succeeded {
                    let successMsg = result.message ?? "Ingestion finished successfully for \(slug) [\(targetMode.shortTitle)]"
                    logger.info("IngestService: \(successMsg, privacy: .public)")
                    self.lastSuccess = successMsg
                    let line = LogLine(stream: .stdout, text: successMsg, source: commandLabel)
                    self.appendLog(line)
                } else {
                    let errorMsg = result.message ?? "Ingestion failed for \(slug) [\(targetMode.shortTitle)]"
                    logger.error("IngestService: \(errorMsg, privacy: .public)")
                    self.lastError = errorMsg
                    let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                    self.appendLog(line)
                }
                cleanup()
            }

            return result
        } catch {
            batchFlushTask.cancel()
            let (remainingLogs, remainingProgress) = batchBuffer.drain()
            let errorMsg = "Ingestion error for \(slug) [\(targetMode.shortTitle)]: \(error.localizedDescription)"
            logger.error("IngestService: \(errorMsg, privacy: .public)")
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if !remainingLogs.isEmpty {
                    self.appendLogs(remainingLogs)
                }
                if !remainingProgress.isEmpty {
                    self.handleProgressBatch(remainingProgress, sourceLabel: commandLabel)
                }
                self.lastError = errorMsg
                let line = LogLine(stream: .stderr, text: errorMsg, source: commandLabel)
                self.appendLog(line)
                cleanup()
            }
            return IngestResult(succeeded: false, message: errorMsg)
        }
    }

    #if DEBUG
    func setRunningForTesting(_ running: Bool) {
        self.isRunning = running
    }
    #endif
}
