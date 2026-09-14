import Foundation
import Darwin
import OSLog
import IngestClient
#if canImport(PythonKit)
import PythonKit
#endif

private let logger = Logger(subsystem: "me.rickmark.garage", category: "GarageMCPServerService")

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

final class GarageMCPServerServiceDelegate: NSObject, NSXPCListenerDelegate, GarageMCPServerServiceProtocol {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }

        #if canImport(PythonKit)
        do {
            logger.info("Initializing Python runtime and linking Python.framework dynamically in GarageMCPServerService...")
            let pyLib = try XPCDyldDiagnostics.initializePythonRuntime()
            logger.info("Python dynamic library successfully loaded via dyld: \(pyLib, privacy: .public)")
            _ = try? Python.attemptImport("garage_rag.mcp_server")
        } catch {
            let errorDetails = XPCDyldDiagnostics.formatError(error)
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageMCPServerService: \(errorDetails)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageMCPServerServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        if let initErr = initializationError {
            reply("pong from GarageMCPServerService (with warning: \(initErr))")
        } else {
            reply("pong from GarageMCPServerService")
        }
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "GarageMCPServerService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let status = initializationError == nil ? "ready" : "warning: \(initializationError!)"
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("GarageMCPServerService setting main app bundle reference: \(bundleURL.path, privacy: .public)")
        XPCDyldDiagnostics.setMainAppBundleURL(bundleURL)
        reply(true, "Main app bundle configured: \(bundleURL.path)")
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

    func startServer(options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(false, "Python initialization error: \(initErr)")
            return
        }
        #if canImport(PythonKit)
        do {
            let os = Python.import("os")
            for (key, value) in options {
                os.environ[key] = PythonObject(value)
            }
            if let dbURL = options["GARAGE_DATABASE_URL"] ?? options["database_url"] {
                os.environ["GARAGE_DATABASE_URL"] = PythonObject(XPCDyldDiagnostics.ensurePsycopgDatabaseURL(dbURL))
            }
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server")
            reply(true, "MCP server module loaded successfully: \(mcpModule)")
        } catch {
            reply(false, "Failed to load MCP server module: \(XPCDyldDiagnostics.formatError(error))")
        }
        #else
        reply(true, "Started without PythonKit")
        #endif
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.startCapturing()
logger.info("GarageMCPServerService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageMCPServerServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
