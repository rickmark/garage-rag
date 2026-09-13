import Foundation
import OSLog
import IngestClient
#if canImport(PythonKit)
import PythonKit
#endif

private let logger = Logger(subsystem: "me.rickmark.garage", category: "GarageEmbedXPCService")

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

@objc public protocol GarageEmbedXPCServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void)
}

final class GarageEmbedXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageEmbedXPCServiceProtocol {
    private var isInitialized = false
    private let initLock = NSLock()
    private(set) var initializationError: String? = nil

    private func setupPythonEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
           FileManager.default.fileExists(atPath: envPath) {
            logger.info("Using explicit PYTHON_LIBRARY environment variable: \(envPath, privacy: .public)")
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_14/Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_14/Python.framework/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Python").path)
        }
        if let fwURL = Bundle.main.privateFrameworksURL {
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Python").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_14/Python.framework/Versions/3.14/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_14/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.14/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Python").path)

        candidatePaths.append("/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/usr/local/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.14/Python")
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

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }
        setupPythonEnvironment()
        #if canImport(PythonKit)
        do {
            logger.info("Attempting to load Python library...")
            try PythonLibrary.loadLibrary()
            logger.info("Python dynamic library successfully loaded via dyld.")

            let sys = Python.import("sys")
            if let resourceURL = Bundle.main.resourceURL {
                let parFile = resourceURL.appendingPathComponent("garage-par")
                if FileManager.default.fileExists(atPath: parFile.path) {
                    sys.path.insert(0, parFile.path)
                }
                sys.path.insert(0, resourceURL.path)
            }
            _ = try? Python.attemptImport("garage_rag.embed")
        } catch {
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            let errorMsg = "Failed to initialize Python environment in GarageEmbedXPCService: \(error.localizedDescription)\(dyldError)"
            initializationError = errorMsg
            fputs("[DYLD_ERROR] \(errorMsg)\n", stderr)
            fflush(stderr)
            logger.error("\(errorMsg, privacy: .public)")
        }
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
        newConnection.exportedObject = self
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

    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        #if canImport(PythonKit)
        Task {
            do {
                let sampleTexts = texts.isEmpty ? ["Garage local retrieval-augmented generation test."] : texts
                let embedModule = try Python.attemptImport("garage_rag.embed")
                var details = "Embed module loaded successfully."
                
                // If get_embedder is available, attempt to get embedder and embed sample text
                if embedModule.get_embedder != Python.None {
                    let modelArg: PythonObject = model != nil ? PythonObject(model!) : Python.None
                    let embedder = try await embedModule.get_embedder.throwing.dynamicallyCall(withKeywordArguments: [("model_name", modelArg)])
                    if embedder.embed_query != Python.None {
                        let vec = try await embedder.embed_query.throwing.dynamicallyCall(withArguments: [sampleTexts[0]])
                        let len = Int(Python.len(vec)) ?? 0
                        let preview = String(describing: vec.take(min(3, len)))
                        details = "Embedded '\(sampleTexts[0].prefix(30))...' successfully. Vector dimensions: \(len), sample: \(preview)"
                    } else if embedder.embed_documents != Python.None {
                        let pyTexts = PythonObject(sampleTexts)
                        let vecs = try await embedder.embed_documents.throwing.dynamicallyCall(withArguments: [pyTexts])
                        let len = Int(Python.len(vecs)) ?? 0
                        details = "Embedded \(sampleTexts.count) document(s) successfully. Output vectors count: \(len)"
                    }
                }
                reply(true, details)
            } catch {
                var tracebackStr = ""
                if let traceback = try? Python.attemptImport("traceback") {
                    tracebackStr = String(describing: traceback.format_exc())
                }
                let errDetails = "Embed execution failed: \(error.localizedDescription)\nTraceback: \(tracebackStr)"
                logger.error("\(errDetails, privacy: .public)")
                reply(false, errDetails)
            }
        }
        #else
        reply(true, "Embedded \(texts.count) test text(s) successfully in mock fallback mode.")
        #endif
    }
}

installCrashHandlers()
logger.info("GarageEmbedXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = GarageEmbedXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
