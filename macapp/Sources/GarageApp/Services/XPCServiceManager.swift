import Foundation
import OSLog
import Darwin

private let logger = Logger(subsystem: "me.rickmark.garage", category: "XPCServiceManager")

/// Objective-C protocol matching the standard `ping` method implemented across all Garage XPC services.
@objc(GarageGenericXPCPingProtocol)
public protocol GarageGenericXPCPingProtocol {
    func ping(with reply: @escaping (String) -> Void)
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

/// Coordinates status checking, real-time pinging, and on-demand restarting for all macOS XPC helper services.
@MainActor
public final class XPCServiceManager: ObservableObject {
    @Published public private(set) var services: [XPCServiceInfo] = []
    @Published public private(set) var isRefreshingAll: Bool = false
    @Published public private(set) var isRestartingAll: Bool = false
    @Published public private(set) var lastRefreshedAt: Date? = nil

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
            return newState
        } catch {
            let errorMsg = error.localizedDescription
            logger.warning("XPC service '\(bundleId, privacy: .public)' ping failed: \(errorMsg, privacy: .public)")
            let newState = XPCServiceState.unreachable(error: errorMsg)
            services[index].state = newState
            services[index].lastChecked = Date()
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

        // If currently running with known PID, send termination signal
        if let currentPid = service.pid, currentPid > 0 {
            logger.info("Terminating existing process for '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
            _ = killExecutor(currentPid)
        }

        // Wait a brief moment for launchd to clean up the dead process
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Ping the service to spawn a fresh instance via launchd / XPC runtime
        let newState = await refresh(serviceId: service.id)
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

        let serviceIds = services.map { $0.id }
        for id in serviceIds {
            _ = await restart(serviceId: id)
        }
    }

    // MARK: - Termination Operations

    /// Terminates all known running XPC helper services.
    public func terminateAll() {
        for service in services {
            if let currentPid = service.pid, currentPid > 0 {
                logger.info("Terminating XPC service '\(service.bundleId, privacy: .public)' (pid: \(currentPid))")
                _ = killExecutor(currentPid)
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
        connection.remoteObjectInterface = NSXPCInterface(with: GarageGenericXPCPingProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(throwing: error)
            }) as? GarageGenericXPCPingProtocol else {
                let err = NSError(domain: "XPCServiceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy for \(bundleId)"])
                relay.resume(throwing: err)
                return
            }

            proxy.ping { reply in
                let durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
                let pid = connection.processIdentifier
                relay.resume(returning: (pid: pid, latencyMs: durationMs, response: reply))
            }
        }
    }
}
