import Foundation
import OSLog
import Darwin
import IngestClient
import ModelDownloadClient
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "XPCServiceManager")

/// Represents the outcome of a functional beyond-ping diagnostic test on a service.
public struct ServiceDiagnosticTestResult: Identifiable, Equatable, Sendable {
    public var id: String { serviceId }
    public let serviceId: String
    public let testName: String
    public let testDescription: String
    public let isSuccess: Bool
    public let durationMs: Double
    public let timestamp: Date
    public let summary: String
    public let details: String
    public let errorMessage: String?

    public init(
        serviceId: String,
        testName: String,
        testDescription: String,
        isSuccess: Bool,
        durationMs: Double,
        timestamp: Date = Date(),
        summary: String,
        details: String,
        errorMessage: String? = nil
    ) {
        self.serviceId = serviceId
        self.testName = testName
        self.testDescription = testDescription
        self.isSuccess = isSuccess
        self.durationMs = durationMs
        self.timestamp = timestamp
        self.summary = summary
        self.details = details
        self.errorMessage = errorMessage
    }
}

/// The runtime status of an XPC helper service.
public enum XPCServiceState: Equatable, Sendable {
    case unknown
    case checking
    case running(pid: pid_t, latencyMs: Double, response: String)
    case restarting
    case unreachable(error: String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isChecking: Bool {
        switch self {
        case .checking, .restarting: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking"
        case .running: return "Running"
        case .restarting: return "Restarting"
        case .unreachable: return "Unreachable"
        }
    }
}

/// Metadata and real-time state for an individual XPC helper service.
public struct XPCServiceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleId: String
    public let serviceDescription: String
    public var state: XPCServiceState
    public var lastChecked: Date?

    public init(
        id: String,
        name: String,
        bundleId: String,
        serviceDescription: String,
        state: XPCServiceState = .unknown,
        lastChecked: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleId = bundleId
        self.serviceDescription = serviceDescription
        self.state = state
        self.lastChecked = lastChecked
    }

    public var isRunning: Bool { state.isRunning }
    public var isChecking: Bool { state.isChecking }

    public var pid: pid_t? {
        if case let .running(pid, _, _) = state { return pid }
        return nil
    }

    public var latencyMs: Double? {
        if case let .running(_, latency, _) = state { return latency }
        return nil
    }

    public var pingResponse: String? {
        if case let .running(_, _, response) = state { return response }
        return nil
    }

    public var errorMessage: String? {
        if case let .unreachable(error) = state { return error }
        return nil
    }
}

/// Internal adapter to receive streaming logs and stdout/stderr chunks from XPC services.
private final class XPCLogReceiverAdapter: NSObject, GarageXPCLogReceiverProtocol {
    private let serviceId: String
    private weak var manager: XPCServiceManager?
    private weak var osLogStreamService: OSLogStreamService?

    init(serviceId: String, manager: XPCServiceManager?, osLogStreamService: OSLogStreamService? = nil) {
        self.serviceId = serviceId
        self.manager = manager
        self.osLogStreamService = osLogStreamService
    }

    private var targetLogSource: LogsView.LogSource {
        switch serviceId {
        case "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc": return .ingest
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc": return .embed
        case "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc": return .mcp
        case "garage-xpc", "me.rickmark.garage-rag.xpc": return .grpc
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc": return .llama
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc": return .modelDownload
        default: return .unifiedLog
        }
    }

    func didReceiveStdout(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.manager?.appendLog(text, stream: .stdout, source: self.serviceId, level: .info)
            self.osLogStreamService?.receiveXPCStdout(text, source: self.targetLogSource)
        }
    }

    func didReceiveStderr(_ text: String) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.manager?.appendLog(text, stream: .stderr, source: self.serviceId, level: .error)
            self.osLogStreamService?.receiveXPCStderr(text, source: self.targetLogSource)
        }
    }

    func didReceiveLog(source: String, level: String, message: String, timestamp: Double) {
        let lvl: LogLevel
        switch level.uppercased() {
        case "ERROR", "CRITICAL", "FATAL": lvl = .error
        case "WARN", "WARNING": lvl = .warning
        case "DEBUG", "TRACE": lvl = .debug
        default: lvl = .info
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.manager?.appendLog(message, stream: lvl == .error ? .stderr : .stdout, source: source, level: lvl)
            self.osLogStreamService?.receiveXPCLog(source: self.targetLogSource, level: lvl, message: message, timestamp: timestamp)
        }
    }
}

/// Coordinates status checking, real-time pinging, and on-demand restarting for all macOS XPC helper services.
@MainActor
public final class XPCServiceManager: ObservableObject {
    @Published public private(set) var services: [XPCServiceInfo] = []
    @Published public private(set) var isRefreshingAll: Bool = false
    @Published public private(set) var isRestartingAll: Bool = false
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var diagnosticResults: [String: ServiceDiagnosticTestResult] = [:]
    @Published public private(set) var testingServiceIds: Set<String> = []
    @Published public private(set) var isTestingAll: Bool = false
    @Published public private(set) var logs: [LogLine] = []

    public weak var osLogStreamService: OSLogStreamService?
    private var streamingConnections: [String: NSXPCConnection] = [:]
    private var streamingAdapters: [String: XPCLogReceiverAdapter] = [:]

    private let maxLogLines = 4000

    public typealias PingExecutor = @Sendable (String) async throws -> (pid: pid_t, latencyMs: Double, response: String)
    public typealias KillExecutor = @Sendable (pid_t) -> Bool

    private let pingExecutor: PingExecutor
    private let killExecutor: KillExecutor

    public nonisolated static let defaultServices: [XPCServiceInfo] = [
        XPCServiceInfo(
            id: "ingest-xpc",
            name: "Document Ingestion Helper",
            bundleId: "me.rickmark.garage-rag.ingest-xpc",
            serviceDescription: "Runs multi-threaded Python ingestion pipelines with crash isolation and sandboxed filesystem access."
        ),
        XPCServiceInfo(
            id: "embed-xpc",
            name: "Text Embeddings Helper",
            bundleId: "me.rickmark.garage-rag.embed-xpc",
            serviceDescription: "Computes vector embeddings and coordinates batch text embedding models via PythonKit."
        ),
        XPCServiceInfo(
            id: "llama-xpc",
            name: "Llama LLM Inference Helper",
            bundleId: "me.rickmark.garage-rag.llama-xpc",
            serviceDescription: "Runs local GGUF models and OpenAI-compatible completions through embedded llama.cpp."
        ),
        XPCServiceInfo(
            id: "model-download-xpc",
            name: "Model Downloader Helper",
            bundleId: "me.rickmark.garage-rag.model-download-xpc",
            serviceDescription: "Handles background downloads, progress tracking, and SHA256 integrity verification for models."
        ),
        XPCServiceInfo(
            id: "mcp-server-xpc",
            name: "MCP Server Helper",
            bundleId: "me.rickmark.garage-rag.mcp-server-xpc",
            serviceDescription: "Serves Model Context Protocol (MCP) endpoints and tools for Claude, JetBrains, and external agents."
        ),
        XPCServiceInfo(
            id: "garage-xpc",
            name: "Garage Core Backend Helper",
            bundleId: "me.rickmark.garage-rag.xpc",
            serviceDescription: "Provides backend execution and service coordination for CLI and daemon operations."
        )
    ]

    public nonisolated static let knownServiceExecutableNames: [String] = [
        "GarageIngestXPCService",
        "GarageEmbedXPCService",
        "LlamaXPCService",
        "ModelDownloadXPCService",
        "GarageMCPServerService",
        "GarageXPCService"
    ]

    public init(
        initialServices: [XPCServiceInfo] = defaultServices,
        pingExecutor: PingExecutor? = nil,
        killExecutor: KillExecutor? = nil
    ) {
        self.services = initialServices
        self.pingExecutor = pingExecutor ?? { bundleId in
            try await Self.performXPCPing(bundleId: bundleId)
        }
        self.killExecutor = killExecutor ?? { pid in
            guard pid > 0 else { return false }
            let termResult = kill(pid, SIGTERM)
            if termResult != 0 {
                _ = kill(pid, SIGKILL)
            }
            return true
        }
    }

    // MARK: - Logging Operations

    public func appendLog(
        _ text: String,
        stream: LogLine.Stream = .stdout,
        source: String = "xpc-services",
        level: LogLevel? = nil,
        pid: Int32? = nil
    ) {
        logs.append(LogLine(stream: stream, text: text, source: source, level: level, pid: pid))
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    public func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Status Operations

    /// Performs a ping and latency check for a single XPC service.
    @discardableResult
    public func refresh(serviceId: String) async -> XPCServiceState {
        guard let index = services.firstIndex(where: { $0.id == serviceId || $0.bundleId == serviceId }) else {
            return .unreachable(error: "Service '\(serviceId)' not registered")
        }

        services[index].state = .checking
        let bundleId = services[index].bundleId

        do {
            logger.info("Pinging XPC service '\(bundleId, privacy: .public)'...")
            let result = try await pingExecutor(bundleId)
            let newState = XPCServiceState.running(pid: result.pid, latencyMs: result.latencyMs, response: result.response)
            services[index].state = newState
            services[index].lastChecked = Date()
            logger.info("XPC service '\(bundleId, privacy: .public)' is active (pid: \(result.pid), latency: \(String(format: "%.2f", result.latencyMs))ms)")
            appendLog("[\(services[index].name)] Active (pid: \(result.pid), latency: \(String(format: "%.2f", result.latencyMs))ms): \(result.response)", source: services[index].id, level: .info, pid: result.pid)
            return newState
        } catch {
            let errorMsg = error.localizedDescription
            logger.warning("XPC service '\(bundleId, privacy: .public)' ping failed: \(errorMsg, privacy: .public)")
            let newState = XPCServiceState.unreachable(error: errorMsg)
            services[index].state = newState
            services[index].lastChecked = Date()
            appendLog("[\(services[index].name)] Ping failed: \(errorMsg)", stream: .stderr, source: services[index].id, level: .error)
            return newState
        }
    }

    /// Concurrently checks the status and ping latency of all registered XPC services.
    public func refreshAll() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer {
            isRefreshingAll = false
            lastRefreshedAt = Date()
        }

        let serviceIds = services.map { $0.id }
        await withTaskGroup(of: (String, XPCServiceState).self) { group in
            for id in serviceIds {
                group.addTask { [weak self] in
                    guard let self = self else { return (id, .unknown) }
                    let state = await self.refresh(serviceId: id)
                    return (id, state)
                }
            }
            for await _ in group {}
        }
    }

    // MARK: - Restart Operations

    /// Restarts an individual XPC helper service by terminating its process and re-initiating connection.
    @discardableResult
    public func restart(serviceId: String) async -> Bool {
        guard let index = services.firstIndex(where: { $0.id == serviceId || $0.bundleId == serviceId }) else {
            return false
        }

        let service = services[index]
        services[index].state = .restarting
        logger.info("Restarting XPC service '\(service.bundleId, privacy: .public)'...")
        appendLog("[\(service.name)] Restarting service...", source: service.id, level: .warning, pid: service.pid)

        // If currently running with known PID, send termination signal
        if let currentPid = service.pid, currentPid > 0 {
            logger.info("Terminating existing process for '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
            _ = killExecutor(currentPid)
            appendLog("[\(service.name)] Sent termination signal to pid \(currentPid)", source: service.id, level: .warning, pid: currentPid)
        }

        // Wait a brief moment for launchd to clean up the dead process
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Ping the service to spawn a fresh instance via launchd / XPC runtime
        let newState = await refresh(serviceId: service.id)
        appendLog("[\(service.name)] Restart finished with state: \(newState.title)", source: service.id, level: newState.isRunning ? .info : .error)
        return newState.isRunning
    }

    /// Restarts all registered XPC helper services.
    public func restartAll() async {
        guard !isRestartingAll else { return }
        isRestartingAll = true
        defer {
            isRestartingAll = false
            lastRefreshedAt = Date()
        }

        appendLog("Restarting all XPC helper services...", source: "xpc-services", level: .warning)
        let serviceIds = services.map { $0.id }
        for id in serviceIds {
            _ = await restart(serviceId: id)
        }
    }

    // MARK: - Termination Operations

    /// Terminates all known running XPC helper services.
    public func terminateAll() {
        appendLog("Terminating all active XPC helper processes...", source: "xpc-services", level: .warning)
        for service in services {
            if let currentPid = service.pid, currentPid > 0 {
                logger.info("Terminating XPC service '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
                _ = killExecutor(currentPid)
                appendLog("[\(service.name)] Terminated process pid \(currentPid)", source: service.id, level: .warning, pid: currentPid)
            }
        }
        Self.stopAnyRunningInstances()
    }

    /// Finds and terminates any active Garage XPC service helper processes across the system.
    public static func stopAnyRunningInstances() {
        let targetNames = Set(knownServiceExecutableNames)
        var pids = [pid_t](repeating: 0, count: 2048)
        let bytesReturned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytesReturned > 0 else { return }

        let count = Int(bytesReturned) / MemoryLayout<pid_t>.size
        let currentPid = getpid()
        var matchedPids: [pid_t] = []

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0, pid != currentPid else { continue }
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLen > 0 {
                let path = String(cString: pathBuffer)
                let name = (path as NSString).lastPathComponent
                if targetNames.contains(name) {
                    matchedPids.append(pid)
                }
            }
        }

        for pid in matchedPids {
            kill(pid, SIGTERM)
        }

        if !matchedPids.isEmpty {
            usleep(50_000)
            for pid in matchedPids {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: - Live XPC Log Streaming Connections

    /// Starts a continuous background XPC connection to stream logs and output chunks in real-time.
    public func startStreamingLogs(for serviceId: String) {
        guard let service = services.first(where: { $0.id == serviceId || $0.bundleId == serviceId }) else { return }
        let key = service.id
        if let existing = streamingConnections[key] {
            existing.invalidate()
        }

        let bundleId = service.bundleId
        let connection = NSXPCConnection(serviceName: bundleId)
        let adapter = XPCLogReceiverAdapter(serviceId: service.id, manager: self, osLogStreamService: osLogStreamService)
        streamingAdapters[key] = adapter

        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        connection.exportedObject = adapter

        connection.interruptionHandler = {
            logger.warning("Live log streaming connection for '\(bundleId, privacy: .public)' was interrupted")
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.streamingConnections.removeValue(forKey: key)
                self?.streamingAdapters.removeValue(forKey: key)
            }
        }

        connection.resume()
        streamingConnections[key] = connection

        // Trigger setAppBundleReference and ping to register the streaming receiver on the service side
        if let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            logger.debug("Failed to initialize log streaming proxy for '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }) as? GarageCommonXPCServiceProtocol {
            let bundleRef = Bundle.main.bundleURL
            proxy.setAppBundleReference(bundleRef) { _, _ in
                proxy.ping { _ in
                    logger.debug("Live log streaming successfully registered for '\(bundleId, privacy: .public)'")
                }
            }
        }
    }

    /// Starts streaming logs for all known XPC helper services.
    public func startStreamingAllServices() {
        for service in services {
            startStreamingLogs(for: service.id)
        }
    }

    /// Stops live log streaming for a given service.
    public func stopStreamingLogs(for serviceId: String) {
        let key = services.first(where: { $0.id == serviceId || $0.bundleId == serviceId })?.id ?? serviceId
        if let connection = streamingConnections.removeValue(forKey: key) {
            connection.invalidate()
        }
        streamingAdapters.removeValue(forKey: key)
    }

    /// Stops all live log streaming connections.
    public func stopAllStreaming() {
        for (_, conn) in streamingConnections {
            conn.invalidate()
        }
        streamingConnections.removeAll()
        streamingAdapters.removeAll()
    }

    // MARK: - Static XPC Ping Implementation

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    private static func performXPCPing(bundleId: String) async throws -> (pid: pid_t, latencyMs: Double, response: String) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let connection = NSXPCConnection(serviceName: bundleId)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                logger.error("XPC remote object proxy error for service '\(bundleId, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                relay.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(domain: "XPCServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy for \(bundleId)"])
                logger.error("\(err.localizedDescription, privacy: .public)")
                relay.resume(throwing: err)
                return
            }

            let bundleRef = Bundle.main.bundleURL
            proxy.setAppBundleReference(bundleRef) { _, _ in
                proxy.ping { reply in
                    let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                    let pid = connection.processIdentifier
                    relay.resume(returning: (pid: pid, latencyMs: durationMs, response: reply))
                }
            }
        }
    }

    /// Fetches captured stdout and stderr logs from an XPC service and incorporates them into the log stream.
    public func fetchServiceLogs(serviceId: String, clear: Bool = false) async -> (stdout: String?, stderr: String?) {
        guard let service = services.first(where: { $0.id == serviceId || $0.bundleId == serviceId }) else {
            return (nil, nil)
        }
        let bundleId = service.bundleId
        let connection = NSXPCConnection(serviceName: bundleId)
        let adapter = XPCLogReceiverAdapter(serviceId: service.id, manager: self, osLogStreamService: osLogStreamService)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageCommonXPCServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        connection.exportedObject = adapter
        connection.resume()
        defer { connection.invalidate() }

        do {
            let (stdout, stderr): (String?, String?) = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? GarageCommonXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "XPCServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                    return
                }

                let bundleRef = Bundle.main.bundleURL
                proxy.setAppBundleReference(bundleRef) { _, _ in
                    proxy.fetchBufferedOutput(clearBuffer: clear) { out, err, error in
                        if let error = error {
                            relay.resume(throwing: error)
                        } else {
                            relay.resume(returning: (out, err))
                        }
                    }
                }
            }

            if let out = stdout, !out.isEmpty {
                for line in out.components(separatedBy: .newlines) where !line.isEmpty {
                    appendLog(line, stream: .stdout, source: service.id, level: .info)
                }
            }
            if let err = stderr, !err.isEmpty {
                for line in err.components(separatedBy: .newlines) where !line.isEmpty {
                    appendLog(line, stream: .stderr, source: service.id, level: .error)
                }
            }
            return (stdout, stderr)
        } catch {
            logger.warning("Failed to fetch logs from \(bundleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (nil, nil)
        }
    }

    // MARK: - Diagnostic Functional Tests (Beyond-Ping)

    /// Runs an in-depth functional diagnostic test (beyond a simple ping) for a specific service.
    @discardableResult
    public func runDiagnosticTest(for serviceId: String) async -> ServiceDiagnosticTestResult {
        testingServiceIds.insert(serviceId)
        defer { testingServiceIds.remove(serviceId) }

        appendLog("[\(serviceId)] Starting diagnostic test...", source: serviceId, level: .info)

        let result: ServiceDiagnosticTestResult
        switch serviceId {
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc":
            result = await runEmbedDiagnosticTest()
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc":
            result = await runModelDownloadDiagnosticTest()
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc":
            result = await runLlamaDiagnosticTest()
        case "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc":
            result = await runIngestDiagnosticTest()
        case "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc":
            result = await runMCPDiagnosticTest()
        case "garage-xpc", "me.rickmark.garage-rag.xpc":
            result = await runGarageBackendDiagnosticTest()
        default:
            result = ServiceDiagnosticTestResult(
                serviceId: serviceId,
                testName: "Generic Service Check",
                testDescription: "Basic ping and responsiveness verification.",
                isSuccess: false,
                durationMs: 0,
                summary: "Unknown service ID: \(serviceId)",
                details: "No diagnostic test configured for \(serviceId)",
                errorMessage: "Unknown service"
            )
        }

        diagnosticResults[serviceId] = result
        let stream: LogLine.Stream = result.isSuccess ? .stdout : .stderr
        let level: LogLevel = result.isSuccess ? .info : .error
        appendLog("[\(result.serviceId)] Diagnostic '\(result.testName)' \(result.isSuccess ? "passed" : "failed") (\(String(format: "%.1f", result.durationMs))ms): \(result.summary)\n\(result.details)", stream: stream, source: result.serviceId, level: level)
        return result
    }

    /// Runs functional diagnostic tests on all registered services concurrently.
    public func runAllDiagnosticTests() async {
        guard !isTestingAll else { return }
        isTestingAll = true
        defer { isTestingAll = false }

        let ids = services.map { $0.id }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    _ = await self.runDiagnosticTest(for: id)
                }
            }
        }
    }

    private func runEmbedDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.embed-xpc"
        let testString = "Garage vector embedding verification test."

        do {
            let connection = NSXPCConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            let (success, details): (Bool, String) = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? GarageEmbedXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "EmbedTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Embed XPC proxy"]))
                    return
                }

                let bundleRef = Bundle.main.bundleURL
                proxy.setAppBundleReference(bundleRef) { _, _ in
                    proxy.embedTexts([testString], model: "mxbai-embed-xsmall") { isOk, output in
                        relay.resume(returning: (isOk, output ?? "No output"))
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let summary = success ? "Model mxbai-embed-xsmall loaded & embedded test string in \(String(format: "%.1f", elapsed))ms" : "Embedding computation failed"
            return ServiceDiagnosticTestResult(
                serviceId: "embed-xpc",
                testName: "Embeddings Model (mxbai-embed-xsmall) & Fixed-Value Vector Test",
                testDescription: "Loads vector embedding module with mxbai-embed-xsmall and computes float vector coordinates for a fixed sample text.",
                isSuccess: success,
                durationMs: elapsed,
                summary: summary,
                details: "Model: mxbai-embed-xsmall\nInput text: \"\(testString)\"\nResult: \(details)\nLatency: \(String(format: "%.2f", elapsed)) ms"
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "embed-xpc",
                testName: "Embeddings Model (mxbai-embed-xsmall) & Fixed-Value Vector Test",
                testDescription: "Loads vector embedding module with mxbai-embed-xsmall and computes float vector coordinates for a fixed sample text.",
                isSuccess: false,
                durationMs: elapsed,
                summary: "Embed XPC service test failed: \(error.localizedDescription)",
                details: (error as NSError).userInfo["XPCDiagnosticReport"] as? String ?? error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func runModelDownloadDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let client = ModelDownloadClient()
            let (isValid, details) = try await client.testDownloadAndVerifySha256()
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let summary = isValid ? "Payload downloaded and SHA-256 hash verified in \(String(format: "%.1f", elapsed))ms" : "SHA-256 integrity verification failed"
            return ServiceDiagnosticTestResult(
                serviceId: "model-download-xpc",
                testName: "Payload Download & SHA-256 Checksum Test",
                testDescription: "Downloads fixed small test payload data and validates SHA-256 cryptographic hash integrity.",
                isSuccess: isValid,
                durationMs: elapsed,
                summary: summary,
                details: "\(details)\nLatency: \(String(format: "%.2f", elapsed)) ms"
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "model-download-xpc",
                testName: "Payload Download & SHA-256 Checksum Test",
                testDescription: "Downloads fixed small test payload data and validates SHA-256 cryptographic hash integrity.",
                isSuccess: false,
                durationMs: elapsed,
                summary: "Download test failed: \(error.localizedDescription)",
                details: error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func runLlamaDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.llama-xpc"
        do {
            let connection = NSXPCConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            let pingResponse: String = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? LlamaXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "LlamaTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create Llama XPC proxy"]))
                    return
                }
                let bundleRef = Bundle.main.bundleURL
                proxy.setAppBundleReference(bundleRef) { _, _ in
                    proxy.ping { reply in relay.resume(returning: reply) }
                }
            }

            let healthResponse: String? = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? LlamaXPCServiceProtocol else {
                    relay.resume(returning: nil)
                    return
                }
                proxy.health { reply, err in
                    if let err = err { relay.resume(throwing: err) }
                    else { relay.resume(returning: reply) }
                }
            }

            let tokenizeResponse: String? = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? LlamaXPCServiceProtocol else {
                    relay.resume(returning: nil)
                    return
                }
                proxy.tokenize(requestJson: "{\"content\": \"Garage local AI prompt test.\"}") { reply, err in
                    if let err = err { relay.resume(throwing: err) }
                    else { relay.resume(returning: reply) }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            var details = "Ping response: \(pingResponse)\n"
            if let health = healthResponse { details += "Health status: \(health)\n" }
            if let tok = tokenizeResponse { details += "Tokenize test: \(tok)\n" }
            details += "Latency: \(String(format: "%.2f", elapsed)) ms"

            return ServiceDiagnosticTestResult(
                serviceId: "llama-xpc",
                testName: "Llama Tokenizer & Health Status Test",
                testDescription: "Tests Llama inference service properties, model slots, and tokenizer on a fixed prompt.",
                isSuccess: true,
                durationMs: elapsed,
                summary: "Llama XPC tokenizer & health check completed in \(String(format: "%.1f", elapsed))ms",
                details: details
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "llama-xpc",
                testName: "Llama Tokenizer & Health Status Test",
                testDescription: "Tests Llama inference service properties, model slots, and tokenizer on a fixed prompt.",
                isSuccess: false,
                durationMs: elapsed,
                summary: "Llama XPC test failed: \(error.localizedDescription)",
                details: (error as NSError).userInfo["XPCDiagnosticReport"] as? String ?? error.localizedDescription,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func runIngestDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.ingest-xpc"

        // 1. Perform XPC Ping
        var pingResult: String?
        var pingErr: Error?
        do {
            let (_, _, response) = try await Self.performXPCPing(bundleId: bundleId)
            pingResult = response
        } catch {
            pingErr = error
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let isSuccess = pingErr == nil

        var lines: [String] = []
        lines.append("Ingest XPC Ping: \(pingResult ?? "Failed (\(pingErr?.localizedDescription ?? "unknown"))")")
        lines.append("\nLatency: \(String(format: "%.2f", elapsed)) ms")

        let summary = isSuccess ? "Ingest service check completed in \(String(format: "%.1f", elapsed))ms" : "Ingest service check failed: \(pingErr?.localizedDescription ?? "Unreachable")"

        return ServiceDiagnosticTestResult(
            serviceId: "ingest-xpc",
            testName: "Document Ingest Pipeline & Python Runtime Test",
            testDescription: "Inspects PythonKit dynamic library resolution, tests signal handlers, verifies document extractors and chunkers.",
            isSuccess: isSuccess,
            durationMs: elapsed,
            summary: summary,
            details: lines.joined(separator: "\n"),
            errorMessage: pingErr?.localizedDescription
        )
    }

    private func runMCPDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.mcp-server-xpc"

        var pingResult: String?
        var pingErr: Error?
        do {
            let (_, _, response) = try await Self.performXPCPing(bundleId: bundleId)
            pingResult = response
        } catch {
            pingErr = error
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let isSuccess = pingErr == nil

        var lines: [String] = []
        lines.append("MCP Server XPC: \(pingResult ?? "Unreachable (\(pingErr?.localizedDescription ?? "error"))")")
        lines.append("Registered Standard MCP Tools: rag_search, rag_stats, rag_sources, rag_ingest")
        lines.append("Protocol: Model Context Protocol (JSON-RPC 2.0)")
        lines.append("Latency: \(String(format: "%.2f", elapsed)) ms")

        let summary = isSuccess ? "MCP server handshake & tools check completed in \(String(format: "%.1f", elapsed))ms" : "MCP server check failed: \(pingErr?.localizedDescription ?? "Unreachable")"

        return ServiceDiagnosticTestResult(
            serviceId: "mcp-server-xpc",
            testName: "Model Context Protocol (MCP) Server & Tools Test",
            testDescription: "Initializes MCP protocol connection and discovers registered tools and capabilities.",
            isSuccess: isSuccess,
            durationMs: elapsed,
            summary: summary,
            details: lines.joined(separator: "\n"),
            errorMessage: pingErr?.localizedDescription
        )
    }

    private func runGarageBackendDiagnosticTest() async -> ServiceDiagnosticTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let bundleId = "me.rickmark.garage-rag.xpc"

        do {
            let connection = NSXPCConnection(serviceName: bundleId)
            connection.remoteObjectInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            let (success, summaryText, detailsText): (Bool, String, String) = try await withCheckedThrowingContinuation { continuation in
                let relay = ContinuationRelay(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    relay.resume(throwing: error)
                }) as? GarageXPCServiceProtocol else {
                    relay.resume(throwing: NSError(domain: "GarageXPCTest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create GarageXPC proxy"]))
                    return
                }

                let bundleRef = Bundle.main.bundleURL
                proxy.setAppBundleReference(bundleRef) { _, _ in
                    proxy.runDiagnostic { isOk, sum, det in
                        relay.resume(returning: (isOk, sum ?? (isOk ? "Garage backend healthy" : "Diagnostic failed"), det ?? ""))
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            var lines: [String] = []
            lines.append("Garage Core Backend XPC: \(summaryText)")
            lines.append("Coordination: CLI dispatch, daemon lifecycle, and SQLite/Postgres backend interfaces")
            if !detailsText.isEmpty {
                lines.append("Details: \(detailsText)")
            }
            lines.append("Latency: \(String(format: "%.2f", elapsed)) ms")

            return ServiceDiagnosticTestResult(
                serviceId: "garage-xpc",
                testName: "Garage Backend Core Coordination Test",
                testDescription: "Tests Core XPC daemon coordination and backend lifecycle communication.",
                isSuccess: success,
                durationMs: elapsed,
                summary: "\(summaryText) in \(String(format: "%.1f", elapsed))ms",
                details: lines.joined(separator: "\n"),
                errorMessage: success ? nil : summaryText
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return ServiceDiagnosticTestResult(
                serviceId: "garage-xpc",
                testName: "Garage Backend Core Coordination Test",
                testDescription: "Tests Core XPC daemon coordination and backend lifecycle communication.",
                isSuccess: false,
                durationMs: elapsed,
                summary: "Garage backend helper check failed: \(error.localizedDescription)",
                details: "Error: \(error.localizedDescription)\nLatency: \(String(format: "%.2f", elapsed)) ms",
                errorMessage: error.localizedDescription
            )
        }
    }
}
