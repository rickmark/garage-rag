import Foundation
import Darwin
import OSLog
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.llama-xpc", category: "LlamaXPCService")

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

final class LlamaXPCServiceDelegate: NSObject, NSXPCListenerDelegate, LlamaXPCServiceProtocol {
    private let engine = LlamaServerEngine.shared

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        logger.info("Accepted incoming XPC connection from PID \(clientPID)")
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
        newConnection.exportedObject = self
        GarageXPCOutputCapture.shared.addConnection(newConnection)
        newConnection.invalidationHandler = { [weak newConnection] in
            logger.info("XPC connection from PID \(clientPID) invalidated")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            logger.warning("XPC connection from PID \(clientPID) interrupted")
            if let conn = newConnection {
                GarageXPCOutputCapture.shared.removeConnection(conn)
            }
        }
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        logger.debug("Handling ping request")
        reply("pong from LlamaXPCService")
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "LlamaXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let status = engine.currentModelPath != nil ? "model_loaded" : "idle"
        logger.debug("Returning service info: name=\(name, privacy: .public), pid=\(pid), uptime=\(uptime), status=\(status, privacy: .public)")
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
        _ = bundleURL.startAccessingSecurityScopedResource()
        reply(true, nil)
    }

    func runDiagnostic(with reply: @escaping (Bool, String?, String?) -> Void) {
        let status = engine.currentModelPath != nil ? "model_loaded" : "idle"
        let summary = "Llama inference engine is healthy (\(status))"
        let details = "Status: \(status), Model: \(engine.currentModelPath ?? "none")"
        reply(true, summary, details)
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
        logger.debug("Clearing captured output logs")
        GarageXPCOutputCapture.shared.clear()
        reply(true)
    }

    func handleGRPCCall(service: String, method: String, payload: Data, with reply: @escaping (Data?, String?, Error?) -> Void) {
        logger.debug("Handling gRPC call over XPC: service=\(service, privacy: .public), method=\(method, privacy: .public)")
        GarageGRPCOverXPCDispatcher.shared.dispatchGRPCCall(service: service, method: method, payload: payload, completion: reply)
    }

    func handleRPC(method: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Handling RPC over XPC: method=\(method, privacy: .public)")
        GarageGRPCOverXPCDispatcher.shared.dispatchRPC(method: method, requestJson: requestJson, completion: reply)
    }

    func health(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleHealth()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func props(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleProps()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func models(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleModels()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling completion request")
            let dict = try engine.handleCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Completion request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling chatCompletion request")
            let dict = try engine.handleChatCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Chat completion request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling embeddings request")
            let dict = try engine.handleEmbeddings(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Embeddings request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling tokenize request")
            let dict = try engine.handleTokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Tokenize request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling detokenize request")
            let dict = try engine.handleDetokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Detokenize request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling rerank request")
            let dict = try engine.handleRerank(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Rerank request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling infill request")
            let dict = try engine.handleInfill(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Infill request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func slots(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleSlots()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling slotAction request: slotId=\(slotId), action=\(action, privacy: .public)")
            let dict = try engine.handleSlotAction(slotId: slotId, action: action, jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("SlotAction request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void) {
        logger.debug("Handling server request: method=\(method, privacy: .public), endpoint=\(endpoint, privacy: .public)")
        let result = engine.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        reply(result.statusCode, result.responseBody, nil)
    }

    func loadModel(modelPath: String, alias: String?, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        logger.info("Loading model from path: \(modelPath, privacy: .public), alias: \(alias ?? "none", privacy: .public)")
        let res = engine.loadModel(path: modelPath, alias: alias, configJson: configJson)
        if res.success {
            logger.info("Model loaded successfully: \(res.message, privacy: .public)")
        } else {
            logger.error("Failed to load model: \(res.message, privacy: .public)")
        }
        reply(res.success, res.message, nil)
    }

    func unloadModel(with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Unloading current model")
        let res = engine.unloadModel()
        reply(res, nil)
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.configure(serviceName: "LlamaXPCService", logFileName: "llama-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()
logger.info("LlamaXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = LlamaXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
