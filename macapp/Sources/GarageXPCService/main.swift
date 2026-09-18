import Foundation
import Darwin
import OSLog
import PythonXPCService_static
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.xpc", category: "GarageXPCService")

private func installCrashHandlers() {
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
        guard !isInitialized else { return }

        do {
            logger.info("Initializing Python runtime (using static linking - no dynamic library loading)...")
            _ = try? Python.attemptImport("garage_rag.service")
        } catch {
            let errorDetails = XPCDyldDiagnostics.formatError(error)
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageXPCService: \(errorDetails)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
        newConnection.exportedObject = self
        GarageXPCOutputCapture.shared.addConnection(newConnection)
        newConnection.invalidationHandler = { [weak newConnection] in
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
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
                os.environ["GARAGE_DATABASE_URL"] = PythonObject(XPCDyldDiagnostics.ensurePsycopgDatabaseURL(dbURL))
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
            let errStr = XPCDyldDiagnostics.formatError(error)
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
            reply(1, nil, "Failed to load service module: \(XPCDyldDiagnostics.formatError(error))")
        }

    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.configure(serviceName: "GarageXPCService", logFileName: "garage-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()
logger.info("GarageXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
