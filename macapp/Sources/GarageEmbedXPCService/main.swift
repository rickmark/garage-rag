import Foundation
import OSLog
import IngestClient
import PythonXPCService
#if canImport(PythonKit)
import PythonKit
#endif

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.embed-xpc", category: "GarageEmbedXPCService")

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

final class GarageEmbedXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageEmbedXPCServiceProtocol {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }

        #if canImport(PythonKit)
        do {
            logger.info("Initializing Python runtime and linking Python.framework dynamically in GarageEmbedXPCService...")
            let pyLib = try XPCDyldDiagnostics.initializePythonRuntime()
            logger.info("Python dynamic library successfully loaded via dyld: \(pyLib, privacy: .public)")
            _ = try? Python.attemptImport("garage_rag.embed")
        } catch {
            let errorDetails = XPCDyldDiagnostics.formatError(error)
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageEmbedXPCService: \(errorDetails)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
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
            reply("pong from GarageEmbedXPCService (with warning: \(initErr))")
        } else {
            reply("pong from GarageEmbedXPCService")
        }
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "GarageEmbedXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let status = initializationError == nil ? "ready" : "warning: \(initializationError!)"
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        XPCDyldDiagnostics.setMainAppBundleURL(bundleURL)
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

    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(false, "Python initialization error: \(initErr)")
            return
        }
        #if canImport(PythonKit)
        Task {
            do {
                let sampleTexts = texts.isEmpty ? ["Garage local retrieval-augmented generation test."] : texts
                let embedModule = try Python.attemptImport("garage_rag.embed")
                var details = "Embed module loaded successfully."
                
                if embedModule.get_embedder != Python.None {
                    let targetModel = model ?? "llama_xpc:mxbai-embed-xsmall"
                    let provider: String
                    let modelRef: String
                    if let colonIdx = targetModel.firstIndex(of: ":") {
                        provider = String(targetModel[..<colonIdx])
                        modelRef = String(targetModel[targetModel.index(after: colonIdx)...])
                    } else {
                        provider = "llama_xpc"
                        modelRef = targetModel
                    }
                    
                    let embedder = try embedModule.get_embedder.throwing.dynamicallyCall(withArguments: [provider, modelRef])
                    if embedder.embed != Python.None {
                        let pyTexts = PythonObject(sampleTexts)
                        let pyVectors = try embedder.embed.throwing.dynamicallyCall(withArguments: [pyTexts])
                        let count = Int(Python.len(pyVectors)) ?? 0
                        var dims = 0
                        if count > 0 {
                            dims = Int(Python.len(pyVectors[0])) ?? 0
                        }
                        details = "Embedded \(sampleTexts.count) text(s) with provider '\(provider)' and model '\(modelRef)' successfully. Generated \(count) vector(s) of dimension \(dims)."
                    }
                }
                reply(true, details)
            } catch {
                let errDetails = "Embed execution failed: \(XPCDyldDiagnostics.formatError(error))"
                logger.error("\(errDetails, privacy: .public)")
                reply(false, errDetails)
            }
        }
        #else
        reply(true, "Embedded \(texts.count) test text(s) successfully in mock fallback mode.")
        #endif
    }

    func embedBatches(model: String?, limit: Int, batchSize: Int, grpcHost: String?, grpcPort: Int, with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        if let initErr = initializationError {
            reply(false, "Python initialization error: \(initErr)")
            return
        }
        #if canImport(PythonKit)
        Task {
            do {
                let embedModule = try Python.attemptImport("garage_rag.embed")
                if embedModule.embed_via_grpc != Python.None {
                    let host = grpcHost ?? "127.0.0.1"
                    let port = grpcPort > 0 ? grpcPort : 50051
                    let pyModel = model != nil ? PythonObject(model!) : Python.None
                    let pyLimit = limit > 0 ? PythonObject(limit) : Python.None
                    let pyBatchSize = batchSize > 0 ? PythonObject(batchSize) : Python.None
                    let resultDict = try await embedModule.embed_via_grpc.throwing.dynamicallyCall(withKeywordArguments: [
                        ("model_slug", pyModel),
                        ("limit", pyLimit),
                        ("batch_size", pyBatchSize),
                        ("grpc_host", PythonObject(host)),
                        ("grpc_port", PythonObject(port))
                    ])
                    let message = String(resultDict["message"]) ?? "Embed via gRPC completed"
                    reply(true, message)
                } else {
                    reply(false, "embed_via_grpc not found in garage_rag.embed")
                }
            } catch {
                let errDetails = "Embed via gRPC failed: \(XPCDyldDiagnostics.formatError(error))"
                logger.error("\(errDetails, privacy: .public)")
                reply(false, errDetails)
            }
        }
        #else
        reply(true, "Mock embedBatches succeeded")
        #endif
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.configure(serviceName: "GarageEmbedXPCService", logFileName: "embed-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()
logger.info("GarageEmbedXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageEmbedXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
