import Foundation
import ModelDownloadClient

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
}

let delegate = ModelDownloadXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
