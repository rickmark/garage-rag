import Foundation
import IngestClient
import OSLog
import PythonKit

private let logger = Logger(subsystem: "me.rickmark.garage", category: "GarageIngestXPCService")

// MARK: - Crash and Signal Handling with Dyld Diagnostics

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

// MARK: - C Callback Definitions and Active Connection Management

private typealias ProgressCFunction = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias LogCFunction = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

final class GarageIngestActiveConnections: @unchecked Sendable {
    static let shared = GarageIngestActiveConnections()

    private var connections = Set<NSXPCConnection>()
    private let lock = NSLock()
    private var _activeIngestSource: String?

    private init() {}

    var activeIngestSource: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _activeIngestSource
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _activeIngestSource = newValue
        }
    }

    func add(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        connections.insert(connection)
        logger.debug("Active XPC connection added (total: \(self.connections.count, privacy: .public))")
    }

    func remove(_ connection: NSXPCConnection) {
        lock.lock()
        defer { lock.unlock() }
        connections.remove(connection)
        logger.debug("Active XPC connection removed (total: \(self.connections.count, privacy: .public))")
    }

    func sendProgress(jsonString: String) {
        let activeConns: [NSXPCConnection]
        lock.lock()
        activeConns = Array(connections)
        lock.unlock()

        for conn in activeConns {
            guard let receiver = conn.remoteObjectProxyWithErrorHandler({ error in
                logger.debug("Progress forwarding error to PID \(conn.processIdentifier): \(error.localizedDescription, privacy: .public)")
            }) as? GarageIngestProgressReceiverProtocol else {
                continue
            }
            receiver.didUpdateProgress(progressJson: jsonString)
        }
    }
}

private let globalProgressCallback: ProgressCFunction = { cStr in
    guard let cStr = cStr else { return }
    let jsonString = String(cString: cStr)
    logger.debug("Ingest C progress callback received: \(jsonString, privacy: .public)")
    GarageIngestActiveConnections.shared.sendProgress(jsonString: jsonString)
}

private let globalLogCallback: LogCFunction = { level, cStr in
    guard let cStr = cStr else { return }
    let msg = String(cString: cStr)
    switch level {
    case 10: // DEBUG
        logger.debug("[Python] \(msg, privacy: .public)")
    case 20: // INFO
        logger.info("[Python] \(msg, privacy: .public)")
    case 30: // WARNING
        logger.warning("[Python] \(msg, privacy: .public)")
    case 40: // ERROR
        logger.error("[Python] \(msg, privacy: .public)")
    case 50: // CRITICAL / FAULT
        logger.fault("[Python] \(msg, privacy: .public)")
    default:
        logger.info("[Python] \(msg, privacy: .public)")
    }
}

final class GarageIngestXPCConnectionHandler: NSObject, GarageIngestXPCServiceProtocol {
    private let connection: NSXPCConnection
    private let engine = IngestEngine.shared
    private let parent: GarageIngestXPCServiceDelegate
    private static let workerQueue = DispatchQueue(label: "me.rickmark.garage.ingest.worker", qos: .userInitiated)

    init(connection: NSXPCConnection, parent: GarageIngestXPCServiceDelegate) {
        self.connection = connection
        self.parent = parent
    }

    func ping(with reply: @escaping (String) -> Void) {
        logger.info("Ping received from client pid: \(self.connection.processIdentifier)")
        if let initErr = parent.initializationError {
            reply("pong from GarageIngestXPCService (with warning: \(initErr))")
        } else {
            reply("pong from GarageIngestXPCService")
        }
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "GarageIngestXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        var status = parent.initializationError == nil ? "ready" : "warning: \(parent.initializationError!)"
        if let current = GarageIngestActiveConnections.shared.activeIngestSource {
            status = "ingesting (\(current))"
        }
        reply(name, pid, uptime, status)
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

    func setRootVolumeBookmark(_ bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting root volume bookmark (\(bookmarkData.count) bytes) from client pid: \(self.connection.processIdentifier)")
        let result = engine.setRootVolumeBookmark(bookmarkData)
        logger.info("Root volume bookmark result: success=\(result.success), message=\(result.message ?? "nil", privacy: .public)")
        reply(result.success, result.message)
    }

    func setSourceBookmark(path: String, bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting source bookmark for path: '\(path, privacy: .public)' (\(bookmarkData.count) bytes) from client pid: \(self.connection.processIdentifier)")
        let result = engine.setSourceBookmark(path: path, bookmarkData: bookmarkData)
        logger.info("Source bookmark result for '\(path, privacy: .public)': success=\(result.success), message=\(result.message ?? "nil", privacy: .public)")
        reply(result.success, result.message)
    }

    func revokeAccess(with reply: @escaping (Bool) -> Void) {
        logger.info("Revoking all volume access bookmarks requested from client pid: \(self.connection.processIdentifier)")
        engine.revokeAccess()
        reply(true)
    }

    func cancelIngest(with reply: @escaping (Bool) -> Void) {
        logger.info("Cancel ingest requested from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        engine.cancel()
        if let initErr = parent.initializationError {
            logger.warning("Cannot cancel ingest via Python because Python is not initialized: \(initErr, privacy: .public)")
            reply(true)
            return
        }
        do {
            let ingestModule = try Python.attemptImport("garage_rag.ingest")
            if ingestModule.cancel_ingest != Python.None {
                _ = try ingestModule.cancel_ingest.throwing.dynamicallyCall(withArguments: [])
                logger.info("Python cancel_ingest invoked successfully")
            }
            reply(true)
        } catch {
            let errorDetails = XPCDyldDiagnostics.formatError(error)
            logger.error("Failed to invoke Python cancel_ingest: \(errorDetails, privacy: .public)")
            reply(false)
        }
    }

    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.info("Testing volume access from client pid: \(self.connection.processIdentifier), request: \(requestJson, privacy: .public)")
        do {
            let request = try engine.deserialize(VolumeAccessTestRequest.self, from: requestJson)
            let result = engine.testVolumeAccess(request: request)
            let responseJson = engine.serialize(result)
            logger.info("Volume access test completed: accessible=\(result.isAccessible), testedPath=\(result.testedPath, privacy: .public), rootItemsCount=\(result.rootItemsCount), message=\(result.message, privacy: .public)")
            reply(responseJson, nil)
        } catch {
            logger.error("Failed volume access test: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    private func applyEnvironmentConfig(databaseUrl: String?, lmStudioApiToken: String?) -> (Bool, String?) {
        if let dbURL = databaseUrl, !dbURL.isEmpty {
            let normalized = XPCDyldDiagnostics.ensurePsycopgDatabaseURL(dbURL)
            setenv("GARAGE_DATABASE_URL", normalized, 1)
            if parent.initializationError == nil {
                if let os = try? Python.attemptImport("os") {
                    os.environ["GARAGE_DATABASE_URL"] = PythonObject(normalized)
                }
                if let configModule = try? Python.attemptImport("garage_rag.config") {
                    if configModule.reset_settings != Python.None {
                        _ = configModule.reset_settings()
                    }
                }
                if let engineModule = try? Python.attemptImport("garage_rag.db.engine") {
                    if engineModule.reset_engine != Python.None {
                        _ = engineModule.reset_engine()
                    }
                }
            }
            logger.info("Successfully configured GARAGE_DATABASE_URL in XPC service: \(normalized, privacy: .public)")
        }
        if let lmToken = lmStudioApiToken, !lmToken.isEmpty {
            setenv("GARAGE_LMSTUDIO_API_TOKEN", lmToken, 1)
            if parent.initializationError == nil {
                if let os = try? Python.attemptImport("os") {
                    os.environ["GARAGE_LMSTUDIO_API_TOKEN"] = PythonObject(lmToken)
                }
            }
            logger.info("Successfully configured GARAGE_LMSTUDIO_API_TOKEN in XPC service")
        }
        return (true, "Environment configured successfully")
    }

    func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Configuring environment from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        if let initErr = parent.initializationError {
            logger.warning("Environment configuration note: Python init: \(initErr, privacy: .public)")
        }
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken)
        reply(success, msg)
    }

    func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Setting database URL from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        if let initErr = parent.initializationError {
            logger.warning("setDatabaseURL note: Python init: \(initErr, privacy: .public)")
        }
        let (success, msg) = applyEnvironmentConfig(databaseUrl: databaseUrl, lmStudioApiToken: lmStudioApiToken)
        reply(success, msg)
    }

    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Received ingestSource request for slug: '\(slug, privacy: .public)', optionsJson: '\(optionsJson, privacy: .public)' from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        if let initErr = parent.initializationError {
            let errorMsg = "Python initialization error: \(initErr)"
            logger.error("\(errorMsg, privacy: .public)")
            reply(false, errorMsg)
            return
        }
        let options = (try? engine.deserialize(IngestOptions.self, from: optionsJson)) ?? .default

        Self.workerQueue.async {
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.info("Starting ingestSource synchronously on worker queue for slug: '\(slug, privacy: .public)'")
            GarageIngestActiveConnections.shared.activeIngestSource = slug
            defer {
                GarageIngestActiveConnections.shared.activeIngestSource = nil
            }
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(slug)"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }

            do {
                _ = self.applyEnvironmentConfig(databaseUrl: options.databaseUrl, lmStudioApiToken: options.lmStudioApiToken)

                logger.info("Importing garage_rag.ingest in Python for slug '\(slug, privacy: .public)'...")
                let ingestModule = try Python.attemptImport("garage_rag.ingest")

                // Register C callback function pointers with Python
                let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
                if ingestModule.set_c_progress_callback != Python.None {
                    ingestModule.set_c_progress_callback(cFuncPtr)
                }

                let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
                if ingestModule.set_c_log_callback != Python.None {
                    ingestModule.set_c_log_callback(cLogFuncPtr)
                }

                let limitObj: PythonObject = options.limit != nil ? PythonObject(options.limit!) : Python.None
                let grpcPortObj: PythonObject = options.grpcPort != nil ? PythonObject(options.grpcPort!) : Python.None
                let grpcHostObj: PythonObject = options.grpcHost != nil ? PythonObject(options.grpcHost!) : Python.None

                logger.info("Invoking Python ingest_xpc synchronously for source '\(slug, privacy: .public)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)), grpcPort: \(String(describing: options.grpcPort)))")
                _ = try ingestModule.ingest_xpc.throwing.dynamicallyCall(withKeywordArguments: [
                     ("source", slug),
                    ("include_code", options.includeCode),
                    ("limit", limitObj),
                    ("force", options.force),
                    ("grpc_host", grpcHostObj),
                    ("grpc_port", grpcPortObj)
                ])

                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let successMsg = "Ingestion completed successfully for \(slug) in \(duration)s"
                logger.info("\(successMsg, privacy: .public)")
                reply(true, successMsg)
            } catch {
                let errorDetails = XPCDyldDiagnostics.formatError(error)
                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let errorMsg = "Failed to run ingest for \(slug) after \(duration)s: \(errorDetails)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }

        }
    }

    func ingestPath(_ source: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Received ingestPath request for source: '\(source, privacy: .public)', options: \(options, privacy: .public) from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        if let initErr = parent.initializationError {
            let errorMsg = "Python initialization error: \(initErr)"
            logger.error("\(errorMsg, privacy: .public)")
            reply(false, errorMsg)
            return
        }

        Self.workerQueue.async {
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.info("Starting ingestPath synchronously on worker queue for source: '\(source, privacy: .public)'")
            GarageIngestActiveConnections.shared.activeIngestSource = source
            defer {
                GarageIngestActiveConnections.shared.activeIngestSource = nil
            }
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(source)"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }

            do {
                let dbURL = options["GARAGE_DATABASE_URL"] ?? options["database_url"] ?? options["databaseUrl"]
                let lmToken = options["GARAGE_LMSTUDIO_API_TOKEN"] ?? options["lmstudio_api_token"] ?? options["lmStudioApiToken"]
                _ = self.applyEnvironmentConfig(databaseUrl: dbURL, lmStudioApiToken: lmToken)

                logger.info("Importing garage_rag.ingest in Python for ingestPath...")
                let ingestModule = try Python.attemptImport("garage_rag.ingest")

                // Register C callback function pointers with Python
                let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
                if ingestModule.set_c_progress_callback != Python.None {
                    ingestModule.set_c_progress_callback(cFuncPtr)
                }

                let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
                if ingestModule.set_c_log_callback != Python.None {
                    ingestModule.set_c_log_callback(cLogFuncPtr)
                }

                let includeCode = options["include_code"] == "true" || options["includeCode"] == "true"
                let force = options["force"] == "true"
                let limitVal = options["limit"].flatMap { Int($0) }
                let limitObj: PythonObject = limitVal != nil ? PythonObject(limitVal!) : Python.None
                let grpcPortVal = options["grpc_port"].flatMap { Int($0) } ?? options["grpcPort"].flatMap { Int($0) }
                let grpcHostVal = options["grpc_host"] ?? options["grpcHost"]
                let grpcPortObj: PythonObject = grpcPortVal != nil ? PythonObject(grpcPortVal!) : Python.None
                let grpcHostObj: PythonObject = grpcHostVal != nil ? PythonObject(grpcHostVal!) : Python.None

                logger.info("Invoking Python ingest_xpc synchronously for path '\(source, privacy: .public)'")
                _ = try ingestModule.ingest_xpc.throwing.dynamicallyCall(withKeywordArguments: [
                    ("source", source),
                    ("include_code", includeCode),
                    ("limit", limitObj),
                    ("force", force),
                    ("grpc_host", grpcHostObj),
                    ("grpc_port", grpcPortObj)
                ])
                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let successMsg = "Ingest completed successfully for: \(source) in \(duration)s"
                logger.info("\(successMsg, privacy: .public)")
                reply(true, successMsg)
            } catch {
                let errorDetails = XPCDyldDiagnostics.formatError(error)
                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let errorMsg = "Failed to run ingest for \(source) after \(duration)s: \(errorDetails)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }

        }
    }
}

final class GarageIngestXPCServiceDelegate: NSObject, NSXPCListenerDelegate {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil

    func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }
        
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = getuid()
        let gid = getgid()
        let host = ProcessInfo.processInfo.hostName
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        let execPath = Bundle.main.executablePath ?? "unknown"

        logger.info("""
        === GarageIngestXPCService Diagnostics Initialization ===
        PID: \(pid), UID: \(uid), GID: \(gid)
        Host: \(host, privacy: .public), OS: \(osVer, privacy: .public)
        Bundle ID: \(bundleID, privacy: .public)
        Bundle Path: \(bundlePath, privacy: .public)
        Executable: \(execPath, privacy: .public)
        =========================================================
        """)

        do {
            logger.info("Initializing Python runtime and linking Python.framework dynamically...")
            let pyLib = try XPCDyldDiagnostics.initializePythonRuntime()
            logger.info("Python dynamic library successfully loaded via dyld: \(pyLib, privacy: .public)")

            logger.info("Importing garage_rag.ingest and setting up logging callbacks...")
            if let ingestModule = try? Python.attemptImport("garage_rag.ingest") {
                logger.info("Successfully imported garage_rag.ingest: \(String(describing: ingestModule), privacy: .public)")

                // Register C callbacks
                let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
                if ingestModule.set_c_progress_callback != Python.None {
                    ingestModule.set_c_progress_callback(cFuncPtr)
                    logger.info("Registered C progress callback with garage_rag.ingest")
                }

                let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
                if ingestModule.set_c_log_callback != Python.None {
                    ingestModule.set_c_log_callback(cLogFuncPtr)
                    logger.info("Registered C log callback with garage_rag.ingest")
                }
            } else {
                logger.warning("garage_rag.ingest could not be imported during startup pre-warming; will be imported on demand.")
            }
        } catch {
            let errorDetails = XPCDyldDiagnostics.formatError(error)
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment: \(errorDetails)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }

        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        let clientEUID = newConnection.effectiveUserIdentifier
        let clientEGID = newConnection.effectiveGroupIdentifier
        logger.info("Ingest XPC listener received connection request from PID: \(clientPID), EUID: \(clientEUID), EGID: \(clientEGID)")

        GarageIngestActiveConnections.shared.add(newConnection)

        let handler = GarageIngestXPCConnectionHandler(connection: newConnection, parent: self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
        newConnection.exportedObject = handler
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)

        newConnection.invalidationHandler = {
            logger.info("Ingest XPC connection invalidated for PID: \(clientPID)")
            GarageIngestActiveConnections.shared.remove(newConnection)
        }
        newConnection.interruptionHandler = {
            logger.warning("Ingest XPC connection interrupted for PID: \(clientPID)")
        }
        newConnection.resume()
        logger.info("Ingest XPC connection accepted and resumed for PID: \(clientPID)")
        return true
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.startCapturing()
logger.info("GarageIngestXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageIngestXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
logger.info("GarageIngestXPCService listener resumed, entering run loop")
RunLoop.main.run()
