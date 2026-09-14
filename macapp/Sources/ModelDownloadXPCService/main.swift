import Foundation
import ModelDownloadClient
import IngestClient

final class ModelDownloadXPCServiceDelegate: NSObject, NSXPCListenerDelegate, ModelDownloadXPCServiceProtocol {
    private let engine = ModelDownloaderEngine.shared

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ModelDownloadXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        reply("pong from ModelDownloadXPCService")
    }

    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void) {
        let name = "ModelDownloadXPCService"
        let pid = ProcessInfo.processInfo.processIdentifier
        let uptime = ProcessInfo.processInfo.systemUptime
        let activeCount = engine.listDownloads().filter { $0.status == .downloading }.count
        let status = activeCount > 0 ? "downloading (\(activeCount) active)" : "idle"
        reply(name, pid, uptime, status)
    }

    func setAppBundleReference(_ bundleURL: URL, with reply: @escaping (Bool, String?) -> Void) {
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

    func startDownload(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let request = try engine.deserialize(ModelDownloadRequest.self, from: requestJson)
            let taskInfo = try engine.startDownload(request: request)
            let responseJson = engine.serialize(taskInfo)
            reply(responseJson, nil)
        } catch {
            reply(nil, error)
        }
    }

    func cancelDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        let success = engine.cancelDownload(taskId: taskId)
        reply(success, nil)
    }

    func pauseDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        let success = engine.pauseDownload(taskId: taskId)
        reply(success, nil)
    }

    func resumeDownload(taskId: String, with reply: @escaping (Bool, Error?) -> Void) {
        let success = engine.resumeDownload(taskId: taskId)
        reply(success, nil)
    }

    func getDownloadStatus(taskId: String, with reply: @escaping (String?, Error?) -> Void) {
        if let info = engine.getDownloadStatus(taskId: taskId), let json = engine.serialize(info) {
            reply(json, nil)
        } else {
            let error = NSError(domain: "ModelDownloadXPCService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Download task not found"])
            reply(nil, error)
        }
    }

    func listDownloads(with reply: @escaping (String?, Error?) -> Void) {
        let downloads = engine.listDownloads()
        let json = engine.serialize(downloads)
        reply(json, nil)
    }

    func listDownloadedModels(directoryPath: String?, with reply: @escaping (String?, Error?) -> Void) {
        let models = engine.listDownloadedModels(directoryPath: directoryPath)
        let json = engine.serialize(models)
        reply(json, nil)
    }

    func deleteDownloadedModel(filePath: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            let success = try engine.deleteDownloadedModel(filePath: filePath)
            reply(success, nil)
        } catch {
            reply(false, error)
        }
    }

    func getModelsDirectory(with reply: @escaping (String) -> Void) {
        let path = engine.getModelsDirectoryPath()
        reply(path)
    }

    func setModelsDirectory(path: String, with reply: @escaping (Bool, Error?) -> Void) {
        do {
            try engine.setModelsDirectory(path: path)
            reply(true, nil)
        } catch {
            reply(false, error)
        }
    }

    func verifyModelFile(filePath: String, expectedSha256: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            let result = try engine.verifyModelFile(filePath: filePath, expectedSha256: expectedSha256)
            reply(result.isValid, result.computedSha256, nil)
        } catch {
            reply(false, nil, error)
        }
    }

    func testDownloadAndVerifySha256(with reply: @escaping (Bool, String?, Error?) -> Void) {
        do {
            let testResult = try engine.testDownloadAndVerifySha256()
            reply(testResult.isValid, testResult.details, nil)
        } catch {
            reply(false, nil, error)
        }
    }

    func downloadFixedTestModel(destinationDirectory: String?, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let task = try engine.downloadFixedTestModel(destinationDirectory: destinationDirectory)
            let json = engine.serialize(task)
            reply(json, nil)
        } catch {
            reply(nil, error)
        }
    }
}

GarageXPCOutputCapture.shared.startCapturing()
let delegate = ModelDownloadXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
