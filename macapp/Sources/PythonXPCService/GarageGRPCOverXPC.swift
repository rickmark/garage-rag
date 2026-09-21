import Foundation
import OSLog

import PythonXPCService_protocol
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageGRPCOverXPC")

/// Dispatches and processes gRPC-over-XPC and JSON-RPC calls within Garage XPC helper services.
public final class GarageGRPCOverXPCDispatcher: @unchecked Sendable {
    public static let shared = GarageGRPCOverXPCDispatcher()

    public typealias BinaryRPCHandler = @Sendable (Data) async throws -> (Data?, String?)
    public typealias JSONRPCHandler = @Sendable (String) async throws -> String

    private let lock = NSLock()
    private var binaryHandlers: [String: BinaryRPCHandler] = [:]
    private var jsonHandlers: [String: JSONRPCHandler] = [:]

    public init() {
        registerDefaultHandlers()
    }

    private func makeKey(service: String, method: String) -> String {
        let cleanService = service.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMethod = method.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanService.isEmpty {
            return cleanMethod.lowercased()
        }
        return "\(cleanService)/\(cleanMethod)".lowercased()
    }

    /// Registers a handler for binary protobuf payload gRPC calls.
    public func registerHandler(service: String = "", method: String, handler: @escaping BinaryRPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        let key = makeKey(service: service, method: method)
        binaryHandlers[key] = handler
    }

    /// Registers a handler for JSON-encoded RPC calls.
    public func registerJSONHandler(method: String, handler: @escaping JSONRPCHandler) {
        lock.lock()
        defer { lock.unlock() }
        jsonHandlers[method.lowercased()] = handler
    }

    /// Registers default handlers for common gRPC inspection and healthcheck methods.
    private func registerDefaultHandlers() {
        // Default JSON Ping handler
        registerJSONHandler(method: "ping") { reqJson in
            let response: [String: Any] = [
                "message": "pong",
                "timestamp": Date().timeIntervalSince1970,
                "pid": ProcessInfo.processInfo.processIdentifier
            ]
            let data = try JSONSerialization.data(withJSONObject: response)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        // Default JSON Status handler
        registerJSONHandler(method: "getstatus") { _ in
            let response: [String: Any] = [
                "version": "0.9",
                "is_ready": true,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "uptime": ProcessInfo.processInfo.systemUptime
            ]
            let data = try JSONSerialization.data(withJSONObject: response)
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        // Default JSON Version handler
        registerJSONHandler(method: "getversion") { _ in
            let response: [String: Any] = [
                "version": "0.9"
            ]
            let data = try JSONSerialization.data(withJSONObject: response)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    /// Dispatches an incoming binary gRPC call over XPC.
    public func dispatchGRPCCall(
        service: String,
        method: String,
        payload: Data,
        completion: @escaping (Data?, String?, Error?) -> Void
    ) {
        let key = makeKey(service: service, method: method)
        let altKey = method.lowercased()

        lock.lock()
        let handler = binaryHandlers[key] ?? binaryHandlers[altKey]
        lock.unlock()

        if let handler = handler {
            Task {
                do {
                    let (resData, message) = try await handler(payload)
                    completion(resData, message, nil)
                } catch {
                    completion(nil, nil, error)
                }
            }
        } else {
            // Check if there is a JSON handler that can handle this method if payload is UTF8 string / JSON
            lock.lock()
            let jHandler = jsonHandlers[altKey]
            lock.unlock()

            if let jHandler = jHandler {
                let jsonStr = String(data: payload, encoding: .utf8) ?? "{}"
                Task {
                    do {
                        let resJson = try await jHandler(jsonStr)
                        let resData = resJson.data(using: .utf8)
                        completion(resData, resJson, nil)
                    } catch {
                        completion(nil, nil, error)
                    }
                }
            } else {
                let err = NSError(
                    domain: "GarageGRPCOverXPC",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Unimplemented gRPC method: \(service)/\(method)"]
                )
                completion(nil, nil, err)
            }
        }
    }

    /// Dispatches an incoming JSON-RPC call over XPC.
    public func dispatchRPC(
        method: String,
        requestJson: String,
        completion: @escaping (String?, Error?) -> Void
    ) {
        let key = method.lowercased()

        lock.lock()
        let handler = jsonHandlers[key]
        lock.unlock()

        if let handler = handler {
            Task {
                do {
                    let result = try await handler(requestJson)
                    completion(result, nil)
                } catch {
                    completion(nil, error)
                }
            }
        } else {
            let err = NSError(
                domain: "GarageGRPCOverXPC",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unimplemented RPC method: \(method)"]
            )
            completion(nil, err)
        }
    }
}

/// Client helper for invoking gRPC and common management methods across XPC connections.
public final class GarageGRPCOverXPCClient: @unchecked Sendable {
    public static let shared = GarageGRPCOverXPCClient()

    public init() {}

    /// Passes the main application bundle to the service: first as an open directory handle (works across
    /// sandbox boundaries and lets the service resolve the real path with `F_GETPATH`), then as a URL.
    private func ensureAppBundleConfigured(proxy: GarageCommonXPCServiceProtocol) async {
        await Self.configureAppBundle(on: proxy)
    }

    /// Shared handshake used by every client: `setAppBundleFileHandle` followed by `setAppBundleReference`.
    public static func configureAppBundle(on proxy: GarageCommonXPCServiceProtocol, bundle: Bundle = .main) async {
        if let handle = FileHandle(forReadingAtPath: bundle.bundlePath) {
            await withCheckedContinuation { continuation in
                proxy.setAppBundleFileHandle(handle) { _, _ in
                    continuation.resume()
                }
            }
            try? handle.close()
        }
        await withCheckedContinuation { continuation in
            proxy.setAppBundleReference(bundle.bundleURL) { _, _ in
                continuation.resume()
            }
        }
    }

    /// Fetches the structured status report (lifecycle, Python runtime, self tests, recent errors).
    public func fetchStatusReport(connection: NSXPCConnection) async throws -> GarageXPCStatusReport {
        let proxy = try makeProxy(connection: connection, onError: { _ in })
        await ensureAppBundleConfigured(proxy: proxy)
        return try await withCheckedThrowingContinuation { continuation in
            let activeProxy: GarageCommonXPCServiceProtocol
            do {
                activeProxy = try makeProxy(connection: connection, onError: { continuation.resume(throwing: $0) })
            } catch {
                continuation.resume(throwing: error)
                return
            }
            activeProxy.getServiceStatus { json in
                if let report = GarageXPCStatusReport.decode(fromJSON: json) {
                    continuation.resume(returning: report)
                } else {
                    continuation.resume(throwing: NSError(domain: "GarageGRPCOverXPCClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Malformed status report: \(json.prefix(200))"]))
                }
            }
        }
    }

    /// Re-runs the service self tests and returns the resulting report.
    public func runSelfTests(connection: NSXPCConnection) async throws -> (passed: Bool, report: GarageXPCStatusReport?) {
        let proxy = try makeProxy(connection: connection, onError: { _ in })
        await ensureAppBundleConfigured(proxy: proxy)
        return try await withCheckedThrowingContinuation { continuation in
            let activeProxy: GarageCommonXPCServiceProtocol
            do {
                activeProxy = try makeProxy(connection: connection, onError: { continuation.resume(throwing: $0) })
            } catch {
                continuation.resume(throwing: error)
                return
            }
            activeProxy.runSelfTests { passed, json in
                continuation.resume(returning: (passed, GarageXPCStatusReport.decode(fromJSON: json)))
            }
        }
    }

    /// Restarts the managed background services inside the helper.
    public func restartServices(graceful: Bool, connection: NSXPCConnection) async throws -> (success: Bool, message: String?) {
        let proxy = try makeProxy(connection: connection, onError: { _ in })
        return try await withCheckedThrowingContinuation { continuation in
            let activeProxy: GarageCommonXPCServiceProtocol
            do {
                activeProxy = try makeProxy(connection: connection, onError: { continuation.resume(throwing: $0) })
            } catch {
                continuation.resume(throwing: error)
                return
            }
            activeProxy.restartServices(graceful: graceful) { success, message in
                continuation.resume(returning: (success, message))
            }
        }
    }

    /// Pushes configuration (database URL, gRPC endpoint, ...) to the helper.
    public func updateConfiguration(_ options: [String: String], connection: NSXPCConnection) async throws -> Bool {
        let proxy = try makeProxy(connection: connection, onError: { _ in })
        return try await withCheckedThrowingContinuation { continuation in
            let activeProxy: GarageCommonXPCServiceProtocol
            do {
                activeProxy = try makeProxy(connection: connection, onError: { continuation.resume(throwing: $0) })
            } catch {
                continuation.resume(throwing: error)
                return
            }
            activeProxy.updateConfiguration(options) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func makeProxy(connection: NSXPCConnection, onError: @escaping (Error) -> Void) throws -> GarageCommonXPCServiceProtocol {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(onError) as? GarageCommonXPCServiceProtocol else {
            throw NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
        }
        return proxy
    }

    /// Dispatches a gRPC call with raw binary payload across an XPC connection.
    public func call(
        service: String = "",
        method: String,
        payload: Data,
        connection: NSXPCConnection
    ) async throws -> (Data?, String?) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageCommonXPCServiceProtocol else {
            let err = NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
            throw err
        }
        await ensureAppBundleConfigured(proxy: proxy)

        return try await withCheckedThrowingContinuation { continuation in
            guard let activeProxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(
                    domain: "GarageGRPCOverXPCClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
                )
                continuation.resume(throwing: err)
                return
            }

            activeProxy.handleGRPCCall(service: service, method: method, payload: payload) { data, message, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, message))
                }
            }
        }
    }

    /// Dispatches a JSON-encoded RPC across an XPC connection.
    public func callJSON(
        method: String,
        requestJson: String,
        connection: NSXPCConnection
    ) async throws -> String {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageCommonXPCServiceProtocol else {
            let err = NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
            throw err
        }
        await ensureAppBundleConfigured(proxy: proxy)

        return try await withCheckedThrowingContinuation { continuation in
            guard let activeProxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(
                    domain: "GarageGRPCOverXPCClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
                )
                continuation.resume(throwing: err)
                return
            }

            activeProxy.handleRPC(method: method, requestJson: requestJson) { responseJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: responseJson ?? "")
                }
            }
        }
    }

    /// Fetches captured stdout and stderr buffers from the XPC service.
    public func fetchLogs(connection: NSXPCConnection) async throws -> (stdout: String?, stderr: String?) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageCommonXPCServiceProtocol else {
            let err = NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
            throw err
        }
        await ensureAppBundleConfigured(proxy: proxy)

        return try await withCheckedThrowingContinuation { continuation in
            guard let activeProxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(
                    domain: "GarageGRPCOverXPCClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
                )
                continuation.resume(throwing: err)
                return
            }

            activeProxy.fetchLogs { stdout, stderr in
                continuation.resume(returning: (stdout, stderr))
            }
        }
    }

    /// Clears the captured stdout and stderr logs in the XPC service.
    public func clearLogs(connection: NSXPCConnection) async throws -> Bool {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageCommonXPCServiceProtocol else {
            let err = NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
            throw err
        }
        await ensureAppBundleConfigured(proxy: proxy)

        return try await withCheckedThrowingContinuation { continuation in
            guard let activeProxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(
                    domain: "GarageGRPCOverXPCClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
                )
                continuation.resume(throwing: err)
                return
            }

            activeProxy.clearLogs { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// Retrieves structured service info from the XPC service.
    public func getServiceInfo(connection: NSXPCConnection) async throws -> (name: String, pid: Int32, uptime: Double, status: String?) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? GarageCommonXPCServiceProtocol else {
            let err = NSError(
                domain: "GarageGRPCOverXPCClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
            )
            throw err
        }
        await ensureAppBundleConfigured(proxy: proxy)

        return try await withCheckedThrowingContinuation { continuation in
            guard let activeProxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageCommonXPCServiceProtocol else {
                let err = NSError(
                    domain: "GarageGRPCOverXPCClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XPC remote object does not conform to GarageCommonXPCServiceProtocol"]
                )
                continuation.resume(throwing: err)
                return
            }

            activeProxy.getServiceInfo { name, pid, uptime, status in
                continuation.resume(returning: (name, pid, uptime, status))
            }
        }
    }
}
