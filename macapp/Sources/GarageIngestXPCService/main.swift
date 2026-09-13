import Foundation
import IngestClient
import OSLog
#if canImport(PythonKit)
import PythonKit
#endif

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

// MARK: - C Callback Definitions

private typealias ProgressCFunction = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias LogCFunction = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

private let globalProgressCallback: ProgressCFunction = { cStr in
    guard let cStr = cStr else { return }
    let jsonString = String(cString: cStr)
    logger.debug("Ingest C progress callback received: \(jsonString, privacy: .public)")
    if let receiver = GarageIngestXPCServiceDelegate.sharedActiveConnection?.remoteObjectProxyWithErrorHandler({ error in
        logger.error("Failed to forward progress update to receiver: \(error.localizedDescription, privacy: .public)")
    }) as? GarageIngestProgressReceiverProtocol {
        receiver.didUpdateProgress(progressJson: jsonString)
    }
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
        #if canImport(PythonKit)
        Task {
            do {
                let ingestModule = try Python.attemptImport("garage_rag.ingest")
                if ingestModule.cancel_ingest != Python.None {
                    _ = try await ingestModule.cancel_ingest.throwing.dynamicallyCall(withArguments: [])
                    logger.info("Python cancel_ingest invoked successfully")
                }
                reply(true)
            } catch {
                var tracebackStr = ""
                if let traceback = try? Python.attemptImport("traceback") {
                    tracebackStr = String(describing: traceback.format_exc())
                }
                logger.error("Failed to invoke Python cancel_ingest: \(error.localizedDescription, privacy: .public)\nTraceback:\n\(tracebackStr, privacy: .public)")
                reply(false)
            }
        }
        #else
        engine.cancel()
        logger.info("Engine cancelled (non-PythonKit)")
        reply(true)
        #endif
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

    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Received ingestSource request for slug: '\(slug, privacy: .public)', optionsJson: '\(optionsJson, privacy: .public)' from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()
        let options = (try? engine.deserialize(IngestOptions.self, from: optionsJson)) ?? .default

        let clientConnection = self.connection
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.info("Starting ingestSource asynchronously for slug: '\(slug, privacy: .public)'")
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(slug)"
            )

            #if canImport(PythonKit)
            do {
                logger.info("Importing garage_rag.ingest in Python for slug '\(slug, privacy: .public)'...")
                let ingestModule = try Python.attemptImport("garage_rag.ingest")

                GarageIngestXPCServiceDelegate.sharedActiveConnection = clientConnection

                // Register C callback function pointers with Python
                let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
                ingestModule.set_c_progress_callback(cFuncPtr)

                let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
                if ingestModule.set_c_log_callback != Python.None {
                    ingestModule.set_c_log_callback(cLogFuncPtr)
                }

                defer {
                    ingestModule.set_c_progress_callback(0)
                    GarageIngestXPCServiceDelegate.sharedActiveConnection = nil
                    ProcessInfo.processInfo.endActivity(activity)
                }

                let limitObj: PythonObject = options.limit != nil ? PythonObject(options.limit!) : Python.None
                let grpcPortObj: PythonObject = options.grpcPort != nil ? PythonObject(options.grpcPort!) : Python.None
                let grpcHostObj: PythonObject = options.grpcHost != nil ? PythonObject(options.grpcHost!) : Python.None

                logger.info("Invoking Python ingest_xpc asynchronously for source '\(slug, privacy: .public)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)), grpcPort: \(String(describing: options.grpcPort)))")
                _ = try await ingestModule.ingest_xpc.throwing.dynamicallyCall(withKeywordArguments: [
                    ("", slug),
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
                var tracebackStr = ""
                if let traceback = try? Python.attemptImport("traceback") {
                    tracebackStr = String(describing: traceback.format_exc())
                }
                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let errorMsg = "Failed to run ingest for \(slug) after \(duration)s: \(error)\nTraceback:\n\(tracebackStr)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }
            #else
            ProcessInfo.processInfo.endActivity(activity)
            logger.info("Ingest completed (stub mode)")
            reply(true, "Ingest completed (stub)")
            #endif
        }
    }

    func ingestPath(_ source: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        logger.info("Received ingestPath request for source: '\(source, privacy: .public)', options: \(options, privacy: .public) from client pid: \(self.connection.processIdentifier)")
        parent.initializePythonIfNeeded()

        let clientConnection = self.connection
        Task {
            let startTime = CFAbsoluteTimeGetCurrent()
            logger.info("Starting ingestPath asynchronously for source: '\(source, privacy: .public)'")
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Garage document ingestion for \(source)"
            )

            #if canImport(PythonKit)
            do {
                logger.info("Importing garage_rag.ingest in Python for ingestPath...")
                let ingestModule = try Python.attemptImport("garage_rag.ingest")

                GarageIngestXPCServiceDelegate.sharedActiveConnection = clientConnection

                // Register C callback function pointers with Python
                let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
                ingestModule.set_c_progress_callback(cFuncPtr)

                let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
                if ingestModule.set_c_log_callback != Python.None {
                    ingestModule.set_c_log_callback(cLogFuncPtr)
                }

                defer {
                    ingestModule.set_c_progress_callback(0)
                    GarageIngestXPCServiceDelegate.sharedActiveConnection = nil
                    ProcessInfo.processInfo.endActivity(activity)
                }

                let includeCode = options["include_code"] == "true" || options["includeCode"] == "true"
                let force = options["force"] == "true"
                let limitVal = options["limit"].flatMap { Int($0) }
                let limitObj: PythonObject = limitVal != nil ? PythonObject(limitVal!) : Python.None
                let grpcPortVal = options["grpc_port"].flatMap { Int($0) } ?? options["grpcPort"].flatMap { Int($0) }
                let grpcHostVal = options["grpc_host"] ?? options["grpcHost"]
                let grpcPortObj: PythonObject = grpcPortVal != nil ? PythonObject(grpcPortVal!) : Python.None
                let grpcHostObj: PythonObject = grpcHostVal != nil ? PythonObject(grpcHostVal!) : Python.None

                logger.info("Invoking Python ingest_xpc asynchronously for path '\(source, privacy: .public)'")
                _ = try await ingestModule.ingest_xpc.throwing.dynamicallyCall(withKeywordArguments: [
                    ("", source),
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
                var tracebackStr = ""
                if let traceback = try? Python.attemptImport("traceback") {
                    tracebackStr = String(describing: traceback.format_exc())
                }
                let duration = String(format: "%.3f", CFAbsoluteTimeGetCurrent() - startTime)
                let errorMsg = "Failed to run ingest for \(source) after \(duration)s: \(error)\nTraceback:\n\(tracebackStr)"
                logger.error("\(errorMsg, privacy: .public)")
                reply(false, errorMsg)
            }
            #else
            ProcessInfo.processInfo.endActivity(activity)
            logger.info("Ingest completed (stub mode)")
            reply(true, "Ingest completed (stub)")
            #endif
        }
    }
}

final class GarageIngestXPCServiceDelegate: NSObject, NSXPCListenerDelegate {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil

    private static let connectionLock = NSLock()
    private static weak var _sharedActiveConnection: NSXPCConnection?

    static var sharedActiveConnection: NSXPCConnection? {
        get {
            connectionLock.lock()
            defer { connectionLock.unlock() }
            return _sharedActiveConnection
        }
        set {
            connectionLock.lock()
            defer { connectionLock.unlock() }
            _sharedActiveConnection = newValue
        }
    }

    private func setupPostgresEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            _ = dlopen(envPath, RTLD_NOW | RTLD_GLOBAL)
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.dylib").path)
            candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.5.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib").path)

        let grandParentURL = parentAppURL.deletingLastPathComponent()
        candidatePaths.append(grandParentURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(grandParentURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                setenv("GARAGE_LIBPQ_PATH", path, 1)
                let libDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                setenv("DYLD_FALLBACK_LIBRARY_PATH", libDir, 1)
                let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
                if handle != nil {
                    logger.info("Successfully loaded postgres libpq via dyld from: \(path, privacy: .public)")
                } else if let errCStr = dlerror() {
                    logger.warning("Failed to dlopen libpq at \(path, privacy: .public): \(String(cString: errCStr), privacy: .public)")
                }
                break
            }
        }
    }

    private func setupPythonEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
           FileManager.default.fileExists(atPath: envPath) {
            logger.info("Using explicit PYTHON_LIBRARY environment variable: \(envPath, privacy: .public)")
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Versions/Current/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/Current/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Python").path)
        }
        if let fwURL = Bundle.main.privateFrameworksURL {
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/Current/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Python").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Python").path)

        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.13/Python")

        let (selectedPath, diagnostics) = XPCDyldDiagnostics.diagnosePythonLibraryLoading(candidatePaths: candidatePaths)
        for diag in diagnostics {
            logger.debug("[Dyld Diagnostic] \(diag, privacy: .public)")
        }

        if let validPath = selectedPath {
            logger.info("Setting PYTHON_LIBRARY to verified path: \(validPath, privacy: .public)")
            setenv("PYTHON_LIBRARY", validPath, 1)
        } else {
            let msg = "[DYLD_WARNING] No valid Python library found among candidate paths:\n" + diagnostics.joined(separator: "\n")
            fputs("\(msg)\n", stderr)
            fflush(stderr)
            logger.warning("\(msg, privacy: .public)")
        }
    }

    func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }
        setupPostgresEnvironment()
        setupPythonEnvironment()
        let pid = ProcessInfo.processInfo.processIdentifier
        let uid = getuid()
        let gid = getgid()
        let euid = geteuid()
        let egid = getegid()
        let host = ProcessInfo.processInfo.hostName
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundlePath
        let execPath = Bundle.main.executablePath ?? "unknown"
        let resourcePath = Bundle.main.resourcePath ?? "unknown"
        let cwd = FileManager.default.currentDirectoryPath
        let home = NSHomeDirectory()
        let tmp = NSTemporaryDirectory()

        logger.info("""
        === GarageIngestXPCService Diagnostics Initialization ===
        PID: \(pid), UID: \(uid), GID: \(gid), EUID: \(euid), EGID: \(egid)
        Host: \(host, privacy: .public), OS: \(osVer, privacy: .public)
        Bundle ID: \(bundleID, privacy: .public)
        Bundle Path: \(bundlePath, privacy: .public)
        Executable: \(execPath, privacy: .public)
        Resource Path: \(resourcePath, privacy: .public)
        CWD: \(cwd, privacy: .public)
        Home: \(home, privacy: .public)
        Tmp: \(tmp, privacy: .public)
        =========================================================
        """)

        #if canImport(PythonKit)
        do {
            logger.info("Attempting to load Python library...")
            try PythonLibrary.loadLibrary()
            logger.info("Python dynamic library successfully loaded via dyld.")

            logger.info("Configuring Python runtime and search paths...")
            let sys = Python.import("sys")
            let pyVersion = String(describing: sys["version"])
            let pyExecutable = String(describing: sys["executable"])
            let pyPrefix = String(describing: sys["prefix"])
            logger.info("Python runtime: version=\(pyVersion, privacy: .public), executable=\(pyExecutable, privacy: .public), prefix=\(pyPrefix, privacy: .public)")

            let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()

            let pythonLibCandidates: [URL?] = [
                parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
                parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
                parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
                parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
                Bundle.main.resourceURL?.appendingPathComponent("python_3_13/Python.framework/Versions/Current/lib/python3.13"),
                Bundle.main.resourceURL?.appendingPathComponent("python_3_13/Python.framework/Versions/3.13/lib/python3.13"),
            ]
            for libURL in pythonLibCandidates {
                if let libURL = libURL, FileManager.default.fileExists(atPath: libURL.path) {
                    logger.info("Found Python standard library at: \(libURL.path, privacy: .public)")
                    sys["path"].insert(0, libURL.path)
                }
            }

            let sitePackagesCandidates: [URL?] = [
                Bundle.main.resourceURL?.appendingPathComponent("site-packages"),
                parentAppURL.appendingPathComponent("Contents/Resources/site-packages"),
                parentAppURL.appendingPathComponent("Resources/site-packages"),
                parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
                parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
                parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
                parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            ]
            for spURL in sitePackagesCandidates {
                if let spURL = spURL, FileManager.default.fileExists(atPath: spURL.path) {
                    logger.info("Found site-packages at: \(spURL.path, privacy: .public)")
                    sys["path"].insert(0, spURL.path)
                }
            }
            if let resourceURL = Bundle.main.resourceURL {
                sys["path"].insert(0, resourceURL.path)
            }
            logger.info("Python sys.path: \(String(describing: sys["path"]), privacy: .public)")

            logger.info("Importing garage_rag.ingest and setting up logging callbacks...")
            let ingestModule = try Python.attemptImport("garage_rag.ingest")
            logger.info("Successfully imported garage_rag.ingest: \(String(describing: ingestModule), privacy: .public)")

            // Register C log callback
            let cLogFuncPtr = unsafeBitCast(globalLogCallback, to: Int.self)
            if ingestModule.set_c_log_callback != Python.None {
                ingestModule.set_c_log_callback(cLogFuncPtr)
                logger.info("Registered C log callback with garage_rag.ingest")
            } else {
                logger.warning("garage_rag.ingest.set_c_log_callback is not available")
            }
        } catch {
            var tracebackStr = ""
            if let traceback = try? Python.attemptImport("traceback") {
                tracebackStr = String(describing: traceback.format_exc())
            }
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment: \(error.localizedDescription)\(dyldError)\nTraceback:\n\(tracebackStr)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        #else
        logger.warning("GarageIngestXPCService compiled without PythonKit support")
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        let clientEUID = newConnection.effectiveUserIdentifier
        let clientEGID = newConnection.effectiveGroupIdentifier
        logger.info("Ingest XPC listener received connection request from PID: \(clientPID), EUID: \(clientEUID), EGID: \(clientEGID)")

        let handler = GarageIngestXPCConnectionHandler(connection: newConnection, parent: self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
        newConnection.exportedObject = handler
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)

        newConnection.invalidationHandler = {
            logger.info("Ingest XPC connection invalidated for PID: \(clientPID)")
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
logger.info("GarageIngestXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageIngestXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
logger.info("GarageIngestXPCService listener resumed, entering run loop")
RunLoop.main.run()
