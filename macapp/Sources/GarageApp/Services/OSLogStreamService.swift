import Foundation
import OSLog
import Combine

private let logger = Logger(subsystem: "me.rickmark.garage", category: "OSLogStreamService")

/// Scope filter for unified logs retrieved from OSLogStore.
public enum OSLogScopeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Garage Logs"
    case ingest = "Ingest"
    case xpc = "XPC Services"
    case system = "Unified Subsystem"

    public var id: String { rawValue }

    public var predicate: NSPredicate {
        switch self {
        case .all:
            return NSPredicate(format: "subsystem == 'me.rickmark.garage' OR process CONTAINS[c] 'Garage'")
        case .ingest:
            return NSPredicate(format: "subsystem == 'me.rickmark.garage' OR category CONTAINS[c] 'ingest' OR category == 'GarageXPCOutputCapture' OR category == 'IngestService' OR category == 'IngestClient' OR category == 'GarageIngestXPCService' OR process CONTAINS[c] 'GarageIngest'")
        case .xpc:
            return NSPredicate(format: "subsystem == 'me.rickmark.garage' OR category CONTAINS[c] 'xpc' OR category CONTAINS[c] 'diagnostics' OR process CONTAINS[c] 'XPC' OR process CONTAINS[c] 'Embed' OR process CONTAINS[c] 'MCPServer' OR process CONTAINS[c] 'Llama' OR process CONTAINS[c] 'ModelDownload'")
        case .system:
            return NSPredicate(format: "subsystem == 'me.rickmark.garage'")
        }
    }
}

/// Time window presets for fetching historical unified logs.
public enum OSLogTimeWindow: String, CaseIterable, Identifiable, Sendable {
    case recent1m = "1 min"
    case recent5m = "5 mins"
    case recent15m = "15 mins"
    case recent1h = "1 hour"
    case recent24h = "24 hours"

    public var id: String { rawValue }

    public var interval: TimeInterval {
        switch self {
        case .recent1m: return 60
        case .recent5m: return 300
        case .recent15m: return 900
        case .recent1h: return 3600
        case .recent24h: return 86400
        }
    }
}

/// A service that continuously queries and streams real-time log entries from Apple's Unified Logging System (`OSLogStore`),
/// distributing logs to per-service streams.
@MainActor
public final class OSLogStreamService: ObservableObject {
    @Published public private(set) var serviceLogs: [LogsView.LogSource: [LogLine]] = [:]
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var lastPolledDate: Date? = nil
    @Published public var scopeFilter: OSLogScopeFilter = .all

    private var streamTask: Task<Void, Never>? = nil
    private var seenLogKeys: Set<String> = []
    private var seenLogKeyQueue: [String] = []
    private let maxSeenKeys = 5000
    private let maxLogLinesPerService = 4000
    private var lastStreamDate: Date = Date().addingTimeInterval(-300)

    public init(startStreaming: Bool = false) {
        if startStreaming {
            self.startStreaming()
        }
    }

    deinit {
        streamTask?.cancel()
    }

    /// Returns all accumulated log lines across unified logging.
    public var logs: [LogLine] {
          []
    }

    /// Returns the accumulated log lines for a specific log source.
    public func logs(for source: LogsView.LogSource) -> [LogLine] {
        serviceLogs[source] ?? []
    }

    // MARK: - Streaming Controls

    /// Starts polling `OSLogStore` for new log entries starting from `since`.
    public func startStreaming(since startDate: Date = Date().addingTimeInterval(-300), pollInterval: TimeInterval = 0.25) {
        stopStreaming()
        isStreaming = true
        isPaused = false
        lastStreamDate = startDate

        guard #available(macOS 12.0, *) else { return }

        // Broad predicate to capture all garage-related unified logs in one pass
        let predicate = NSPredicate(format: "subsystem == 'me.rickmark.garage' OR process CONTAINS[c] 'Garage'")

        streamTask = Task { [weak self] in
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
                logger.debug("OSLogStreamService: Failed to open OSLogStore")
                return
            }

            var lastDate = startDate
            var lastPosition = store.position(date: startDate)

            while !Task.isCancelled {
                guard let self = self else { break }

                let paused = await MainActor.run { self.isPaused }
                if !paused {
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
                                    self.processOSLogEntry(entry)
                                }
                            }
                        }

                        lastDate = maxDate
                        lastPosition = store.position(date: lastDate)
                        await MainActor.run {
                            self.lastPolledDate = Date()
                            self.lastStreamDate = lastDate
                        }
                    } catch {
                        logger.debug("OSLogStreamService: OSLogStore polling error: \(error.localizedDescription, privacy: .public)")
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    /// Stops polling `OSLogStore`.
    public func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        isPaused = false
    }

    /// Pauses streaming without cancelling the task.
    public func pauseStreaming() {
        isPaused = true
    }

    /// Resumes streaming if paused.
    public func resumeStreaming() {
        isPaused = false
    }

    /// Toggles between paused and active streaming.
    public func togglePause() {
        if !isStreaming {
            startStreaming(since: lastStreamDate)
        } else {
            isPaused.toggle()
        }
    }

    /// Restarts streaming with the current scope filter and time bounds.
    public func restartStreaming() {
        startStreaming(since: lastStreamDate)
    }

    /// Drains recent entries from `OSLogStore` within a given time window.
    public func fetchRecentLogs(for source: LogsView.LogSource? = nil, timeWindow: TimeInterval = 300) {
        guard #available(macOS 12.0, *) else { return }
        let startDate = Date().addingTimeInterval(-timeWindow)
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let position = store.position(date: startDate)

        let predicate: NSPredicate
        if let source = source, let sourcePredicate = source.osLogPredicate {
            predicate = sourcePredicate
        } else {
            predicate = NSPredicate(format: "subsystem == 'me.rickmark.garage' OR process CONTAINS[c] 'Garage'")
        }

        do {
            let entries = try store.getEntries(at: position, matching: predicate)
            for entry in entries {
                processOSLogEntry(entry)
            }
            lastPolledDate = Date()
        } catch {
            logger.debug("OSLogStreamService: OSLogStore fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears recorded log lines for a specific source, or all sources if nil.
    public func clearLogs(for source: LogsView.LogSource? = nil) {
        if let source = source {
            serviceLogs[source] = []
        } else {
            serviceLogs.removeAll()
            seenLogKeys.removeAll()
            seenLogKeyQueue.removeAll()
        }
    }

    // MARK: - Entry Processing

    /// Target mapping: routes an OSLogEntryLog to the appropriate service log streams.
    public func targetSources(for logEntry: OSLogEntryLog) -> Set<LogsView.LogSource> {
        var targets: Set<LogsView.LogSource> = []
        let category = logEntry.category.lowercased()
        let process = logEntry.process.lowercased()
        let message = logEntry.composedMessage

        // Ingest
        if category.contains("ingest") ||
            category == "garagexpcoutputcapture" ||
            category == "ingestservice" ||
            category == "ingestclient" ||
            category == "garageingestxpcservice" ||
            process.contains("garageingest") ||
            message.hasPrefix("[Python]") {
            targets.insert(.ingest)
        }

        // Embedding / Backfill
        if category.contains("embed") || category.contains("backfill") || process.contains("embed") {
            targets.insert(.backfill)
        }

        // MCP Server
        if category.contains("mcp") || process.contains("mcp") {
            targets.insert(.mcp)
        }

        // gRPC Server
        if category.contains("grpc") || process.contains("grpc") {
            targets.insert(.grpc)
        }

        // Llama Service
        if category.contains("llama") || process.contains("llama") {
            targets.insert(.llama)
        }

        // Model Downloader
        if category.contains("modeldownload") || process.contains("modeldownload") {
            targets.insert(.modelDownload)
        }



        return targets
    }

    /// Processes an individual `OSLogEntry` and converts it to a `LogLine`.
    public func processOSLogEntry(_ entry: OSLogEntry) {
        guard let logEntry = entry as? OSLogEntryLog else { return }
        let category = logEntry.category
        let message = logEntry.composedMessage
        let process = logEntry.process

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
            level = LogLine.inferLevel(stream: stream, text: message)
        }

        let sourceLabel: String
        if !category.isEmpty {
            sourceLabel = category
        } else if !process.isEmpty {
            sourceLabel = process
        } else {
            sourceLabel = "OSLog"
        }

        let line = LogLine(
            id: UUID(),
            date: logEntry.date,
            stream: stream,
            text: message,
            source: sourceLabel,
            level: level,
            pid: logEntry.processIdentifier
        )

        let targets = targetSources(for: logEntry)
        appendLog(line, for: targets)
    }

    /// Appends a new `LogLine` to target services while deduplicating by text content, source, and timestamp bucket.
    public func appendLog(_ line: LogLine, for targets: Set<LogsView.LogSource>) {
        let textTrimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textTrimmed.isEmpty else { return }

        let timeBucket = Int(line.date.timeIntervalSince1970)
        let key = "\(textTrimmed)|\(timeBucket)|\(line.source)|\(line.pid ?? 0)"

        if seenLogKeys.contains(key) {
            return
        }
        seenLogKeys.insert(key)
        seenLogKeyQueue.append(key)
        if seenLogKeyQueue.count > maxSeenKeys {
            let removed = seenLogKeyQueue.removeFirst()
            seenLogKeys.remove(removed)
        }

        for target in targets {
            var current = serviceLogs[target] ?? []
            current.append(line)
            if current.count > maxLogLinesPerService {
                current.removeFirst(current.count - maxLogLinesPerService)
            }
            serviceLogs[target] = current
        }
    }
}
