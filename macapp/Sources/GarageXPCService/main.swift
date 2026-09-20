import Foundation
import Darwin
import OSLog
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.xpc", category: "GarageXPCService")

// MARK: - Crash and Signal Handling with Dyld Diagnostics

private func installCrashHandlers() {
    logger.debug("Installing fatal signal and uncaught exception crash handlers...")
    NSSetUncaughtExceptionHandler { exception in
        let callStack = exception.callStackSymbols.joined(separator: "\n  ")
        let msg = "CRITICAL: Uncaught NSException '\(exception.name.rawValue)': \(exception.reason ?? "none")\nUserInfo: \(String(describing: exception.userInfo))\nCall Stack:\n  \(callStack)\n"
        fputs(msg, stderr)
        fflush(stderr)
        logger.fault("CRITICAL: Uncaught NSException '\(exception.name.rawValue, privacy: .public)': \(exception.reason ?? "none", privacy: .public)\nUserInfo: \(String(describing: exception.userInfo), privacy: .public)\nCall Stack:\n  \(callStack, privacy: .public)")
    }

    let fatalSignals: [Int32] = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP, SIGPIPE]
    for sig in fatalSignals {
        signal(sig) { signum in
            let sigName: String
            switch signum {
            case SIGSEGV: sigName = "SIGSEGV (Segmentation Fault)"
            case SIGBUS: sigName = "SIGBUS (Bus Error)"
            case SIGABRT: sigName = "SIGABRT (Abort)"
            case SIGILL: sigName = "SIGILL (Illegal Instruction)"
            case SIGFPE: sigName = "SIGFPE (Floating Point Exception)"
            case SIGTRAP: sigName = "SIGTRAP (Trace/BPT Trap)"
            case SIGPIPE: sigName = "SIGPIPE (Broken Pipe)"
            default: sigName = "Signal \(signum)"
            }

            var dyldMsg = ""
            if let errCStr = dlerror() {
                dyldMsg = " | dyld error: \(String(cString: errCStr))"
            }

            let callStack = Thread.callStackSymbols.joined(separator: "\n  ")
            let msg = "CRITICAL: Process received fatal signal \(sigName) (\(signum))\(dyldMsg).\nCall Stack:\n  \(callStack)\n"
            fputs(msg, stderr)
            fflush(stderr)
            logger.fault("CRITICAL: Process received fatal signal \(sigName, privacy: .public) (\(signum))\(dyldMsg, privacy: .public). Call Stack:\n  \(callStack, privacy: .public)")

            signal(signum, SIG_DFL)
            raise(signum)
        }
    }
    logger.debug("Crash handlers installed successfully.")
}

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
        if isInitialized {
            logger.debug("Python runtime already initialized (status: \(self.initializationError == nil ? "ready" : "error", privacy: .public))")
            return
        }

        logger.info("Initializing Python runtime (using static linking - no dynamic library loading)...")
        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let serviceModule = try Python.attemptImport("garage_rag.service")
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            logger.info("Python runtime initialized and 'garage_rag.service' imported successfully in \(String(format: "%.3f", elapsed), privacy: .public)s: \(String(describing: serviceModule), privacy: .public)")
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageXPCService: \(error.localizedDescription)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("Python initialization failed after \(String(format: "%.3f", elapsed), privacy: .public)s: \(errorMsg, privacy: .public)")
        }
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        logger.info("Incoming connection request received from PID \(clientPID, privacy: .public)...")

        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
        newConnection.exportedObject = self

        GarageXPCOutputCapture.shared.addConnection(newConnection)

        newConnection.invalidationHandler = { [weak newConnection] in
            logger.info("XPC connection invalidated for PID \(clientPID, privacy: .public)")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            logger.warning("XPC connection interrupted for PID \(clientPID, privacy: .public)")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }

        newConnection.resume()
        logger.info("Accepted and resumed incoming XPC connection for PID \(clientPID, privacy: .public)")
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        logger.debug("Received ping request")
        let response: String
        if let initErr = initializationError {
            response = "pong from GarageXPCService (with warning: \(initErr))"
            logger.warning("Replying to ping with initialization warning: \(initErr, privacy: .public)")
        } else {
            response = "pong from GarageXPCService"
            logger.debug("Replying to ping: \(response, privacy: .public)")
        }
        reply(response)
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "GarageXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let status = initializationError == nil ? "ready" : "warning: \(initializationError!)"
        logger.info("getServiceInfo called -> service: \(name, privacy: .public), PID: \(pid, privacy: .public), uptime: \(String(format: "%.1f", uptime), privacy: .public)s, status: \(status, privacy: .public)")
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("setAppBundleReference received URL: \(bundleURL.path, privacy: .public)")
        let accessed = bundleURL.startAccessingSecurityScopedResource()
        logger.info("startAccessingSecurityScopedResource returned \(accessed, privacy: .public) for path: \(bundleURL.path, privacy: .public)")
        reply(true, nil)
    }

    func runDiagnostic(with reply: @escaping (Bool, String?, String?) -> Void) {
        logger.info("runDiagnostic initiated")
        initializePythonIfNeeded()
        if let initErr = initializationError {
            logger.error("Diagnostic failed due to Python initialization error: \(initErr, privacy: .public)")
            reply(false, "Python initialization error", initErr)
            return
        }
        do {
            let serviceModule = try Python.attemptImport("garage_rag.service")
            let summary = "Garage backend service module verified"
            let details = "Successfully loaded service module: \(serviceModule)"
            logger.info("Diagnostic succeeded: \(summary, privacy: .public) - \(details, privacy: .public)")
            reply(true, summary, details)
        } catch {
            let errDesc = error.localizedDescription
            logger.error("Diagnostic failed to load service module: \(errDesc, privacy: .public)")
            reply(false, "Failed to load service module", errDesc)
        }
    }

    func fetchLogs(with reply: @escaping (String?, String?) -> Void) {
        logger.debug("fetchLogs requested (clearBuffer: false)")
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: false)
        let outLen = out.count
        let errLen = err.count
        logger.debug("fetchLogs returning stdout (\(outLen, privacy: .public) chars), stderr (\(errLen, privacy: .public) chars)")
        reply(out, err)
    }

    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void) {
        logger.debug("fetchBufferedOutput requested (clearBuffer: \(clearBuffer, privacy: .public))")
        let (out, err) = GarageXPCOutputCapture.shared.fetchLogs(clearBuffer: clearBuffer)
        let outLen = out.count
        let errLen = err.count
        logger.debug("fetchBufferedOutput returning stdout (\(outLen, privacy: .public) chars), stderr (\(errLen, privacy: .public) chars)")
        reply(out, err, nil)
    }

    func clearLogs(with reply: @escaping (Bool) -> Void) {
        logger.info("clearLogs requested")
        GarageXPCOutputCapture.shared.clear()
        logger.info("clearLogs completed")
        reply(true)
    }

    func handleGRPCCall(service: String, method: String, payload: Data, with reply: @escaping (Data?, String?, Error?) -> Void) {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("handleGRPCCall dispatching service: '\(service, privacy: .public)', method: '\(method, privacy: .public)', payloadSize: \(payload.count, privacy: .public) bytes")
        GarageGRPCOverXPCDispatcher.shared.dispatchGRPCCall(service: service, method: method, payload: payload) { responseData, statusString, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if let error = error {
                logger.error("handleGRPCCall failed for \(service, privacy: .public)/\(method, privacy: .public) after \(String(format: "%.3f", elapsed), privacy: .public)s: \(error.localizedDescription, privacy: .public)")
            } else {
                let respSize = responseData?.count ?? 0
                logger.info("handleGRPCCall completed for \(service, privacy: .public)/\(method, privacy: .public) in \(String(format: "%.3f", elapsed), privacy: .public)s, responseSize: \(respSize, privacy: .public) bytes, status: \(statusString ?? "ok", privacy: .public)")
            }
            reply(responseData, statusString, error)
        }
    }

    func handleRPC(method: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        let startTime = CFAbsoluteTimeGetCurrent()
        logger.info("handleRPC dispatching method: '\(method, privacy: .public)', requestJsonSize: \(requestJson.count, privacy: .public) chars")
        GarageGRPCOverXPCDispatcher.shared.dispatchRPC(method: method, requestJson: requestJson) { responseJson, error in
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if let error = error {
                logger.error("handleRPC failed for method '\(method, privacy: .public)' after \(String(format: "%.3f", elapsed), privacy: .public)s: \(error.localizedDescription, privacy: .public)")
            } else {
                let respSize = responseJson?.count ?? 0
                logger.info("handleRPC completed for method '\(method, privacy: .public)' in \(String(format: "%.3f", elapsed), privacy: .public)s, responseJsonSize: \(respSize, privacy: .public) chars")
            }
            reply(responseJson, error)
        }
    }

    func startServer(host: String, port: Int, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("startServer requested for host: '\(host, privacy: .public)', port: \(port, privacy: .public), options count: \(options.count, privacy: .public) (keys: \(options.keys.joined(separator: ", "), privacy: .public))")
        initializePythonIfNeeded()
        if let initErr = initializationError {
            logger.error("startServer failed due to Python initialization error: \(initErr, privacy: .public)")
            reply(false, "Python initialization error: \(initErr)")
            return
        }
        serverLock.lock()
        defer { serverLock.unlock() }
        do {
            let os = Python.import("os")
            for (key, value) in options {
                os.environ[key] = PythonObject(value)
                logger.debug("Set Python environment variable: \(key, privacy: .public)")
            }
            if let dbURL = options["GARAGE_DATABASE_URL"] ?? options["database_url"] {
                var normalized = dbURL
                if normalized.hasPrefix("postgresql://"), !normalized.hasPrefix("postgresql+psycopg://") {
                    let suffix = normalized.dropFirst("postgresql://".count)
                    normalized = "postgresql+psycopg://\(suffix)"
                    logger.info("Normalized PostgreSQL database URL scheme to postgresql+psycopg://")
                } else if normalized.hasPrefix("postgres://") {
                    let suffix = normalized.dropFirst("postgres://".count)
                    normalized = "postgresql+psycopg://\(suffix)"
                    logger.info("Normalized Postgres database URL scheme to postgresql+psycopg://")
                }
                os.environ["GARAGE_DATABASE_URL"] = PythonObject(normalized)
            }
            if let server = activeServer {
                logger.info("Stopping existing active gRPC server before restarting...")
                if let stopEvent = activeStopEvent {
                    logger.debug("Setting stop event on existing active server...")
                    _ = stopEvent.set()
                }
                _ = server.stop(grace: 1.0)
                activeServer = nil
                activeStopEvent = nil
                logger.info("Previous gRPC server stopped.")
            }
            logger.debug("Importing Python threading and garage_rag.service.server...")
            let threading = Python.import("threading")
            let stopEvent = threading.Event()
            let serverModule = try Python.attemptImport("garage_rag.service.server")
            logger.debug("Creating gRPC server instance on \(host, privacy: .public):\(port)...")
            let serverTuple = serverModule.create_grpc_server(host: host, port: port, stop_event: stopEvent)
            let server = serverTuple[0]
            logger.debug("Starting gRPC server...")
            _ = server.start()
            self.activeServer = server
            self.activeStopEvent = stopEvent
            let msg = "gRPC server started on \(host):\(port)"
            logger.info("Garage gRPC server started successfully on \(host, privacy: .public):\(port)")
            reply(true, msg)
        } catch {
            let errStr = error.localizedDescription
            logger.error("Failed to start gRPC server on \(host, privacy: .public):\(port): \(errStr, privacy: .public)")
            reply(false, "Failed to start gRPC server: \(errStr)")
        }
    }

    func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        logger.info("stopServer requested")
        serverLock.lock()
        defer { serverLock.unlock() }
        if let server = activeServer {
            logger.info("Stopping active gRPC server...")
            if let stopEvent = activeStopEvent {
                logger.debug("Signaling stop event...")
                _ = stopEvent.set()
            }
            _ = server.stop(grace: 1.0)
            activeServer = nil
            activeStopEvent = nil
            logger.info("Garage gRPC server stopped successfully")
            reply(true, "gRPC server stopped")
            return
        }
        logger.info("stopServer called but no active server was running")
        reply(true, "gRPC server was not running")
    }

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        serverLock.lock()
        defer { serverLock.unlock() }
        let running = (activeServer != nil)
        logger.debug("isServerRunning checked -> \(running, privacy: .public)")
        reply(running)
    }

    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void) {
        logger.info("executeCommand requested: '\(command, privacy: .public)' with arguments: \(arguments, privacy: .public)")
        initializePythonIfNeeded()
        if let initErr = initializationError {
            logger.error("executeCommand failed due to Python initialization error: \(initErr, privacy: .public)")
            reply(1, nil, "Python initialization error: \(initErr)")
            return
        }
        do {
            let serviceModule = try Python.attemptImport("garage_rag.service")
            let msg = "Service module loaded successfully: \(serviceModule)"
            logger.info("executeCommand completed successfully: \(msg, privacy: .public)")
            reply(0, msg, nil)
        } catch {
            let errStr = error.localizedDescription
            logger.error("executeCommand failed to load service module: \(errStr, privacy: .public)")
            reply(1, nil, "Failed to load service module: \(errStr)")
        }
    }
}

// MARK: - Process Entry Point

installCrashHandlers()

GarageXPCOutputCapture.shared.configure(serviceName: "GarageXPCService", logFileName: "garage-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()

let processInfo = ProcessInfo.processInfo
logger.info("GarageXPCService starting up (PID: \(processInfo.processIdentifier, privacy: .public), ProcessName: \(processInfo.processName, privacy: .public), OS: \(processInfo.operatingSystemVersionString, privacy: .public), Arguments: \(processInfo.arguments, privacy: .public))...")

let delegate = GarageXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
logger.info("Resuming NSXPCListener for GarageXPCService...")
listener.resume()
logger.info("GarageXPCService listener resumed; entering dispatchMain().")
dispatchMain()