import Foundation
import Darwin
import OSLog
import PythonXPCService
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.mcp-server-xpc", category: "GarageMCPServerService")

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
    private var isRunningServer = false
    private let serverLock = NSLock()

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }

        do {
            logger.info("Initializing Python runtime (using static linking - no dynamic library loading)...")
            _ = try? Python.attemptImport("garage_rag.mcp_server")
        } catch {
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageMCPServerService: \(error.localizedDescription)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageMCPServerServiceProtocol.self)
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
        // Start accessing bundle URL to extend sandbox
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

    func startServer(host: String, port: Int, path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
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
                // Normalize database URL to ensure psycopg is used
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
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
            let success = Bool(mcpModule.start_background_server(
                host: host,
                port: port,
                path: path
            )) ?? true
            self.isRunningServer = success
            logger.info("Garage MCP server started on \(host, privacy: .public):\(port)\(path, privacy: .public)")
            reply(success, "MCP server started on \(host):\(port)\(path)")
        } catch {
            let errStr = error.localizedDescription
            logger.error("Failed to start MCP server: \(errStr, privacy: .public)")
            reply(false, "Failed to start MCP server: \(errStr)")
        }
    }

    func stopServer(with reply: @escaping (Bool, String?) -> Void) {
        serverLock.lock()
        defer { serverLock.unlock() }
        do {
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
            let success = Bool(mcpModule.stop_background_server()) ?? true
            self.isRunningServer = false
            logger.info("Garage MCP server stopped")
            reply(success, "MCP server stopped")
            return
        } catch {
            self.isRunningServer = false
            reply(true, "MCP server stopped with warning: \(error.localizedDescription)")
            return
        }
    }

    func isServerRunning(with reply: @escaping (Bool) -> Void) {
        serverLock.lock()
        defer { serverLock.unlock() }
        do {
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
            let running = Bool(mcpModule.is_background_server_running()) ?? self.isRunningServer
            reply(running)
        } catch {
            reply(self.isRunningServer)
        }
    }

    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(1, nil, "Python initialization error: \(initErr)")
            return
        }
        do {
            let cliRunnerModule = try Python.attemptImport("typer.testing")
            let appModule = try Python.attemptImport("garage_rag.cli")
            let runner = cliRunnerModule.CliRunner()
            var fullArgs: [String] = []
            if !command.isEmpty {
                fullArgs.append(command)
            }
            fullArgs.append(contentsOf: arguments)
            let result = runner.invoke(appModule.app, PythonObject(fullArgs))
            let exitCode = Int32(result.exit_code) ?? 0
            let stdout = String(result.stdout)
            let stderr = String(result.stderr)
            reply(exitCode, stdout, stderr)
        } catch {
            let errStr = error.localizedDescription
            reply(1, nil, "Failed to execute command: \(errStr)")
        }
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.configure(serviceName: "GarageMCPServerService", logFileName: "mcp-server-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()
logger.info("GarageMCPServerService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageMCPServerServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
