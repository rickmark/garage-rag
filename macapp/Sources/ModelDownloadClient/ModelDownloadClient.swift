import Foundation

/// High-level Swift client for communicating with `ModelDownloadXPCService`.
public final class ModelDownloadClient: Sendable {
    public static let serviceName = "me.rickmark.garage-rag.model-download-xpc"

    private let inProcessEngine: ModelDownloaderEngine?
    private let customServiceName: String?

    public init(serviceName: String = ModelDownloadClient.serviceName) {
        self.customServiceName = serviceName
        self.inProcessEngine = nil
    }

    /// Creates a client using an in-process engine (e.g., for unit tests or standalone execution).
    public init(inProcessEngine: ModelDownloaderEngine) {
        self.inProcessEngine = inProcessEngine
        self.customServiceName = nil
    }

    // MARK: - XPC Connection

    private func makeConnection() -> NSXPCConnection {
        let name = customServiceName ?? ModelDownloadClient.serviceName
        let connection = NSXPCConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadXPCServiceProtocol.self)
        connection.resume()
        return connection
    }

    // MARK: - API Methods

    public func ping() async throws -> String {
        if let engine = inProcessEngine {
            _ = engine
            return "pong from in-process ModelDownloadClient"
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.ping { reply in
                continuation.resume(returning: reply)
            }
        }
    }

    public func startDownload(request: ModelDownloadRequest) async throws -> DownloadTaskInfo {
        if let engine = inProcessEngine {
            return try engine.startDownload(request: request)
        }

        guard let jsonString = ModelDownloaderEngine.shared.serialize(request) else {
            throw NSError(domain: "ModelDownloadClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode download request"])
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.startDownload(requestJson: jsonString) { replyJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let taskInfo = try ModelDownloaderEngine.shared.deserialize(DownloadTaskInfo.self, from: replyJson)
                        continuation.resume(returning: taskInfo)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty reply from service"]))
                }
            }
        }
    }

    public func startDownload(url: URL, filename: String? = nil, authToken: String? = nil) async throws -> DownloadTaskInfo {
        let req = ModelDownloadRequest(url: url.absoluteString, filename: filename, authToken: authToken)
        return try await startDownload(request: req)
    }

    public func cancelDownload(taskId: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.cancelDownload(taskId: taskId)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.cancelDownload(taskId: taskId) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    public func pauseDownload(taskId: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.pauseDownload(taskId: taskId)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.pauseDownload(taskId: taskId) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    public func resumeDownload(taskId: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.resumeDownload(taskId: taskId)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.resumeDownload(taskId: taskId) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    public func getDownloadStatus(taskId: String) async throws -> DownloadTaskInfo {
        if let engine = inProcessEngine {
            guard let info = engine.getDownloadStatus(taskId: taskId) else {
                throw NSError(domain: "ModelDownloadClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task not found"])
            }
            return info
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.getDownloadStatus(taskId: taskId) { replyJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let info = try ModelDownloaderEngine.shared.deserialize(DownloadTaskInfo.self, from: replyJson)
                        continuation.resume(returning: info)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task not found"]))
                }
            }
        }
    }

    public func listDownloads() async throws -> [DownloadTaskInfo] {
        if let engine = inProcessEngine {
            return engine.listDownloads()
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.listDownloads { replyJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let list = try ModelDownloaderEngine.shared.deserialize([DownloadTaskInfo].self, from: replyJson)
                        continuation.resume(returning: list)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public func listDownloadedModels(directoryPath: String? = nil) async throws -> [DownloadedModelInfo] {
        if let engine = inProcessEngine {
            return engine.listDownloadedModels(directoryPath: directoryPath)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.listDownloadedModels(directoryPath: directoryPath) { replyJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let list = try ModelDownloaderEngine.shared.deserialize([DownloadedModelInfo].self, from: replyJson)
                        continuation.resume(returning: list)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    public func deleteDownloadedModel(at path: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return try engine.deleteDownloadedModel(filePath: path)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.deleteDownloadedModel(filePath: path) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    public func getModelsDirectory() async throws -> String {
        if let engine = inProcessEngine {
            return engine.getModelsDirectoryPath()
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.getModelsDirectory { path in
                continuation.resume(returning: path)
            }
        }
    }

    public func setModelsDirectory(path: String) async throws -> Bool {
        if let engine = inProcessEngine {
            try engine.setModelsDirectory(path: path)
            return true
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.setModelsDirectory(path: path) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    public func verifyModelFile(at path: String, expectedSha256: String? = nil) async throws -> (isValid: Bool, sha256: String) {
        if let engine = inProcessEngine {
            let res = try engine.verifyModelFile(filePath: path, expectedSha256: expectedSha256)
            return (res.isValid, res.computedSha256)
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.verifyModelFile(filePath: path, expectedSha256: expectedSha256) { isValid, computedHash, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let computedHash = computedHash {
                    continuation.resume(returning: (isValid, computedHash))
                } else {
                    continuation.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty checksum verification reply"]))
                }
            }
        }
    }
}
