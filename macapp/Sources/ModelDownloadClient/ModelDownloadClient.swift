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

    // MARK: - Relay & Remote Call Helper

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    private func performRemoteCall<T>(
        _ block: @escaping (ModelDownloadXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(throwing: error)
            }) as? ModelDownloadXPCServiceProtocol else {
                relay.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            block(proxy, relay)
        }
    }

    // MARK: - API Methods

    public func ping() async throws -> String {
        if let engine = inProcessEngine {
            _ = engine
            return "pong from in-process ModelDownloadClient"
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.ping { reply in
                    relay.resume(returning: reply)
                }
            }
        } catch {
            return "pong (in-process fallback)"
        }
    }

    public func startDownload(request: ModelDownloadRequest) async throws -> DownloadTaskInfo {
        if let engine = inProcessEngine {
            return try engine.startDownload(request: request)
        }

        guard let jsonString = ModelDownloaderEngine.shared.serialize(request) else {
            throw NSError(domain: "ModelDownloadClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode download request"])
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.startDownload(requestJson: jsonString) { replyJson, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let replyJson = replyJson {
                        do {
                            let taskInfo = try ModelDownloaderEngine.shared.deserialize(DownloadTaskInfo.self, from: replyJson)
                            relay.resume(returning: taskInfo)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty reply from service"]))
                    }
                }
            }
        } catch {
            return try ModelDownloaderEngine.shared.startDownload(request: request)
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

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.cancelDownload(taskId: taskId) { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else {
                        relay.resume(returning: success)
                    }
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.cancelDownload(taskId: taskId)
        }
    }

    public func pauseDownload(taskId: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.pauseDownload(taskId: taskId)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.pauseDownload(taskId: taskId) { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else {
                        relay.resume(returning: success)
                    }
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.pauseDownload(taskId: taskId)
        }
    }

    public func resumeDownload(taskId: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.resumeDownload(taskId: taskId)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.resumeDownload(taskId: taskId) { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else {
                        relay.resume(returning: success)
                    }
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.resumeDownload(taskId: taskId)
        }
    }

    public func getDownloadStatus(taskId: String) async throws -> DownloadTaskInfo {
        if let engine = inProcessEngine {
            guard let info = engine.getDownloadStatus(taskId: taskId) else {
                throw NSError(domain: "ModelDownloadClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task not found"])
            }
            return info
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.getDownloadStatus(taskId: taskId) { replyJson, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let replyJson = replyJson {
                        do {
                            let info = try ModelDownloaderEngine.shared.deserialize(DownloadTaskInfo.self, from: replyJson)
                            relay.resume(returning: info)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(throwing: NSError(domain: "ModelDownloadClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task not found"]))
                    }
                }
            }
        } catch {
            guard let info = ModelDownloaderEngine.shared.getDownloadStatus(taskId: taskId) else {
                throw NSError(domain: "ModelDownloadClient", code: 404, userInfo: [NSLocalizedDescriptionKey: "Task not found"])
            }
            return info
        }
    }

    public func listDownloads() async throws -> [DownloadTaskInfo] {
        if let engine = inProcessEngine {
            return engine.listDownloads()
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.listDownloads { replyJson, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let replyJson = replyJson {
                        do {
                            let list = try ModelDownloaderEngine.shared.deserialize([DownloadTaskInfo].self, from: replyJson)
                            relay.resume(returning: list)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(returning: [])
                    }
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.listDownloads()
        }
    }

    public func listDownloadedModels(directoryPath: String? = nil) async throws -> [DownloadedModelInfo] {
        if let engine = inProcessEngine {
            return engine.listDownloadedModels(directoryPath: directoryPath)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.listDownloadedModels(directoryPath: directoryPath) { replyJson, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let replyJson = replyJson {
                        do {
                            let list = try ModelDownloaderEngine.shared.deserialize([DownloadedModelInfo].self, from: replyJson)
                            relay.resume(returning: list)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(returning: [])
                    }
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.listDownloadedModels(directoryPath: directoryPath)
        }
    }

    public func deleteDownloadedModel(at path: String) async throws -> Bool {
        if let engine = inProcessEngine {
            return try engine.deleteDownloadedModel(filePath: path)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.deleteDownloadedModel(filePath: path) { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else {
                        relay.resume(returning: success)
                    }
                }
            }
        } catch {
            return try ModelDownloaderEngine.shared.deleteDownloadedModel(filePath: path)
        }
    }

    public func getModelsDirectory() async throws -> String {
        if let engine = inProcessEngine {
            return engine.getModelsDirectoryPath()
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.getModelsDirectory { path in
                    relay.resume(returning: path)
                }
            }
        } catch {
            return ModelDownloaderEngine.shared.getModelsDirectoryPath()
        }
    }

    public func setModelsDirectory(path: String) async throws -> Bool {
        if let engine = inProcessEngine {
            try engine.setModelsDirectory(path: path)
            return true
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.setModelsDirectory(path: path) { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else {
                        relay.resume(returning: success)
                    }
                }
            }
        } catch {
            try ModelDownloaderEngine.shared.setModelsDirectory(path: path)
            return true
        }
    }

    public func verifyModelFile(at path: String, expectedSha256: String? = nil) async throws -> (isValid: Bool, sha256: String) {
        if let engine = inProcessEngine {
            let res = try engine.verifyModelFile(filePath: path, expectedSha256: expectedSha256)
            return (res.isValid, res.computedSha256)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.verifyModelFile(filePath: path, expectedSha256: expectedSha256) { isValid, computedHash, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let computedHash = computedHash {
                        relay.resume(returning: (isValid, computedHash))
                    } else {
                        relay.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty checksum verification reply"]))
                    }
                }
            }
        } catch {
            let res = try ModelDownloaderEngine.shared.verifyModelFile(filePath: path, expectedSha256: expectedSha256)
            return (res.isValid, res.computedSha256)
        }
    }

    /// Downloads a fixed small value and verifies its SHA-256 hash.
    public func testDownloadAndVerifySha256() async throws -> (isValid: Bool, details: String) {
        if let engine = inProcessEngine {
            let res = try engine.testDownloadAndVerifySha256()
            return (res.isValid, res.details)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.testDownloadAndVerifySha256 { isValid, details, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let details = details {
                        relay.resume(returning: (isValid, details))
                    } else {
                        relay.resume(returning: (isValid, "Completed without details"))
                    }
                }
            }
        } catch {
            let res = try ModelDownloaderEngine.shared.testDownloadAndVerifySha256()
            return (res.isValid, res.details)
        }
    }

    /// Downloads the fixed mxbai-embed-xsmall test model resource.
    public func downloadFixedTestModel(destinationDirectory: String? = nil) async throws -> DownloadTaskInfo {
        if let engine = inProcessEngine {
            return try engine.downloadFixedTestModel(destinationDirectory: destinationDirectory)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.downloadFixedTestModel(destinationDirectory: destinationDirectory) { jsonString, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let jsonString = jsonString {
                        do {
                            let task = try ModelDownloaderEngine.shared.deserialize(DownloadTaskInfo.self, from: jsonString)
                            relay.resume(returning: task)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(throwing: NSError(domain: "ModelDownloadClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty download task response"]))
                    }
                }
            }
        } catch {
            return try ModelDownloaderEngine.shared.downloadFixedTestModel(destinationDirectory: destinationDirectory)
        }
    }
}
