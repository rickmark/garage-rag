import Foundation
import Darwin
import OSLog
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "GarageXPCService")

final class GarageXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageXPCServiceProtocol {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil
    private var activeServer: PythonObject? = nil
    private var activeStopEvent: PythonObject? = nil
    private let serverLock = NSLock()

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }

        do {
            logger.info("Initializing Python runtime (using static linking - no dynamic library loading)...")
            _ = try? Python.attemptImport("garage_rag.service")
        } catch {
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageXPCService: \(error.localizedDescription)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.info("Accepting incoming connection...")
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        if let initErr = initializationError {
            reply("pong from GarageXPCService (with warning: \(initErr))")
        } else {
            reply("pong from GarageXPCService")
        }
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "GarageXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let status = initializationError == nil ? "ready" : "warning: \(initializationError!)"
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        _ = bundleURL.startAccessingSecurityScopedResource()
        reply(true, nil)
    }

    func fetchLogs(with reply: @escaping (String?, String?) -> Void) {
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: false)
        reply(out, err)
    }

    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void) {
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: clearBuffer)
        reply(out, err, nil)
    }

    func clearLogs(with reply: @escaping (Bool) -> Void) {
        GarageXPCOutputCapture.shared.clear()
        reply(true)
    }

    func handleGRPCCall(service: String, method: String, payload: Data, with reply: @escaping (Data?, String?, Error?) -> Void) {
        GarageGRPCOverXPCDispatcher.shared.dispatchGRPCCall(service: service, method: method, payload: payload, completion: reply)
    }

    func handleRPC(method: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        GarageGRPCOverXPCDispatcher.shared.dispatchRPC(method: method, requestJson: requestJson, completion: reply)
    }

    func startServer(host: String, port: Int, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(false, "Python initialization error: \(initErr)")
            return
        }
        serverLock.lock()
        defer { serverLock.unlock() }
        do {
            let os = Python.import("os")
            for (key, value) in options {
                os.environ[key] = PythonObject(value)
            }
            if let dbURL = options["GARAGE_DATABASE_URL"] ?? options["database_url"] {
                var normalized = dbURL
                if normalized.hasPrefix("postgresql://"), !normalized.hasPrefix("postgresql+psycopg://") {
                    let suffix = normalized.dropFirst("postgresql://".count)
                    normalized = "postgresql+psycopg://\(suffix)"
                } else if normalized.hasPrefix("postgres://") {
                    let suffix = normalized.dropFirst("postgres://".count)
                    normalized = "postgresql+psycopg://\(suffix)"
                }
                os.environ["GARAGE_DATABASE_URL"] = PythonObject(normalized)
            }
            if let server = activeServer {
                if let stopEvent = activeStopEvent {
                    _ = stopEvent.set()
                }
                _ = server.stop(grace: 1.0)
                activeServer = nil
                activeStopEvent = nil
            }
            let threading = Python.import("threading")
            let stopEvent = threading.Event()
            let serverModule = try Python.attemptImport("garage_rag.service.server")
            let serverTuple = serverModule.create_grpc_server(host: host, port: port, stop_event: stopEvent)
            let server = serverTuple[0]
            _ = server.start()
            self.activeServer = server
            self.activeStopEvent = stopEvent
            logger.info("Garage gRPC server started on \(host, privacy: .public):\(port)")
            reply(true, "gRPC server started on \(host):\(port)")
        } catch {
            let errStr = error.localizedDescription
            logger.error("Failed to start gRPC server: \(errStr, privacy: .public)")
            reply(false, "Failed to start gRPC server: \(errStr)")
        }
    }

    func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        serverLock.lock()
        defer { serverLock.unlock() }
        if let server = activeServer {
            if let stopEvent = activeStopEvent {
                _ = stopEvent.set()
            }
            _ = server.stop(grace: 1.0)
            activeServer = nil
            activeStopEvent = nil
            logger.info("Garage gRPC server stopped")
            reply(true, "gRPC server stopped")
            return
        }
        reply(true, "gRPC server was not running")
    }

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        serverLock.lock()
        defer { serverLock.unlock() }
        reply(activeServer != nil)
    }

    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(1, nil, "Python initialization error: \(initErr)")
            return
        }
        do {
            let serviceModule = try Python.attemptImport("garage_rag.service")
            reply(0, "Service module loaded successfully: \(serviceModule)", nil)
        } catch {
            reply(1, nil, "Failed to load service module: \(error.localizedDescription)")
        }

    }
}

logger.info("GarageXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
dispatchMain()