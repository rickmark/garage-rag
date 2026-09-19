import Foundation
import Darwin
import OSLog
import ModelDownloadClient
import PythonXPCService_static

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.model-download-xpc", category: "ModelDownloadXPCService")

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

final class ModelDownloadXPCServiceDelegate: NSObject, NSXPCListenerDelegate, ModelDownloadXPCServiceProtocol {
    private let engine = ModelDownloaderEngine.shared

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let clientPID = newConnection.processIdentifier
        logger.info("Accepted incoming XPC connection from PID \(clientPID)")
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageXPCLogReceiverProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: ModelDownloadXPCServiceProtocol.self)
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
        reply("pong from ModelDownloadXPCService")
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "ModelDownloadXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let activeCount = engine.listDownloads().filter { $0.status == .downloading }.count
        let status = activeCount > 0 ? "downloading (\(activeCount) active)" : "idle"
        logger.debug("Returning service info: name=\(name, privacy: .public), pid=\(pid), uptime=\(uptime), status=\(status, privacy: .public)")
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

    func startDownload(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.info("Starting model download")
            let request = try engine.deserialize(ModelDownloadRequest.self, from: requestJson)
            let taskInfo = try engine.startDownload(request: request)
            logger.info("Download task started with ID: \(taskInfo.id, privacy: .public) for URL: \(taskInfo.url, privacy: .public)")
            let responseJson = engine.serialize(taskInfo)
            reply(responseJson, nil)
        } catch {
            logger.error("Failed to start download: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func cancelDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Canceling download task: \(taskId, privacy: .public)")
        let success = engine.cancelDownload(taskId: taskId)
        reply(success, nil)
    }

    func pauseDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Pausing download task: \(taskId, privacy: .public)")
        let success = engine.pauseDownload(taskId: taskId)
        reply(success, nil)
    }

    func resumeDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Resuming download task: \(taskId, privacy: .public)")
        let success = engine.resumeDownload(taskId: taskId)
        reply(success, nil)
    }

    func getDownloadStatus(taskId: String, with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Getting download status for task: \(taskId, privacy: .public)")
        if let info = engine.getDownloadStatus(taskId: taskId), let json = engine.serialize(info) {
            reply(json, nil)
        } else {
            logger.warning("Download task not found: \(taskId, privacy: .public)")
            let error = NSError(domain: "ModelDownloadXPCService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Download task not found"])
            reply(nil, error)
        }
    }

    func listDownloads(with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Listing download tasks")
        let downloads = engine.listDownloads()
        let json = engine.serialize(downloads)
        reply(json, nil)
    }

    func listDownloadedModels(directoryPath: String?, with reply: @escaping (String?, Error?) -> Void) {
        logger.debug("Listing downloaded models in directory: \(directoryPath ?? "default", privacy: .public)")
        let models = engine.listDownloadedModels(directoryPath: directoryPath)
        let json = engine.serialize(models)
        reply(json, nil)
    }

    func deleteDownloadedModel(filePath: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            logger.info("Deleting downloaded model at path: \(filePath, privacy: .public)")
            let success = try engine.deleteDownloadedModel(filePath: filePath)
            reply(success, nil)
        } catch {
            logger.error("Failed to delete model at path \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, error)
        }
    }

    func getModelsDirectory(with reply: @escaping (String) -> Void) {
        let path = engine.getModelsDirectoryPath()
        logger.debug("Getting models directory: \(path, privacy: .public)")
        reply(path)
    }

    func setModelsDirectory(path: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            logger.info("Setting models directory to: \(path, privacy: .public)")
            try engine.setModelsDirectory(path: path)
            reply(true, nil)
        } catch {
            logger.error("Failed to set models directory to \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, error)
        }
    }

    func verifyModelFile(filePath: String, expectedSha256: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            logger.info("Verifying model file at path: \(filePath, privacy: .public)")
            let result = try engine.verifyModelFile(filePath: filePath, expectedSha256: expectedSha256)
            reply(result.isValid, result.computedSha256, nil)
        } catch {
            logger.error("Failed to verify model file at \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            reply(false, nil, error)
        }
    }

    func testDownloadAndVerifySha256(with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            logger.info("Running test download and SHA256 verification")
            let testResult = try engine.testDownloadAndVerifySha256()
            reply(testResult.isValid, testResult.details, nil)
        } catch {
            logger.error("Test download and verification failed: \(error.localizedDescription, privacy: .public)")
            reply(false, nil, error)
        }
    }

    func downloadFixedTestModel(destinationDirectory: String?, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.info("Starting fixed test model download")
            let task = try engine.downloadFixedTestModel(destinationDirectory: destinationDirectory)
            let json = engine.serialize(task)
            reply(json, nil)
        } catch {
            logger.error("Fixed test model download failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }
}

installCrashHandlers()
GarageXPCOutputCapture.shared.configure(serviceName: "ModelDownloadXPCService", logFileName: "model-download-xpc.log")
GarageXPCOutputCapture.shared.startCapturing()
logger.info("ModelDownloadXPCService starting up (PID: \(ProcessInfo.processInfo.processIdentifier))...")
let delegate = ModelDownloadXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
