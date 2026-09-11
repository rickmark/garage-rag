import Foundation

/// Progress receiver adapter for XPC callbacks.
private final class IngestProgressReceiver: NSObject, GarageIngestProgressReceiverProtocol {
    private let onProgress: @Sendable (IngestProgressUpdate) -> Void
    private let engine = IngestEngine.shared

    init(onProgress: @escaping @Sendable (IngestProgressUpdate) -> Void) {
        self.onProgress = onProgress
    }

    func didUpdateProgress(progressJson: String) {
        if let update = try? engine.deserialize(IngestProgressUpdate.self, from: progressJson) {
            onProgress(update)
        }
    }
}

/// High-level Swift client for communicating with `GarageIngestXPCService`.
public final class IngestClient: Sendable {
    public static let serviceName = IngestXPCConstants.serviceName

    private let inProcessEngine: IngestEngine?
    private let customServiceName: String?

    public init(serviceName: String = IngestClient.serviceName) {
        self.customServiceName = serviceName
        self.inProcessEngine = nil
    }

    public init(inProcessEngine: IngestEngine) {
        self.inProcessEngine = inProcessEngine
        self.customServiceName = nil
    }

    // MARK: - XPC Connection Helper

    private func makeConnection(progressReceiver: GarageIngestProgressReceiverProtocol? = nil) -> NSXPCConnection {
        let name = customServiceName ?? IngestClient.serviceName
        let connection = NSXPCConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)

        if let receiver = progressReceiver {
            connection.exportedInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)
            connection.exportedObject = receiver
        }

        connection.resume()
        return connection
    }

    // MARK: - API Methods

    public func ping() async throws -> String {
        if let engine = inProcessEngine {
            _ = engine
            return "pong from in-process IngestEngine"
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.ping { reply in
                continuation.resume(returning: reply)
            }
        }
    }

    public func setRootVolumeBookmark(_ bookmarkData: Data) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.setRootVolumeBookmark(bookmarkData).success
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.setRootVolumeBookmark(bookmarkData) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    public func setSourceBookmark(path: String, bookmarkData: Data) async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.setSourceBookmark(path: path, bookmarkData: bookmarkData).success
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.setSourceBookmark(path: path, bookmarkData: bookmarkData) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    public func revokeAccess() async throws -> Bool {
        if let engine = inProcessEngine {
            engine.revokeAccess()
            return true
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.revokeAccess { success in
                continuation.resume(returning: success)
            }
        }
    }

    public func testVolumeAccess(request: VolumeAccessTestRequest) async throws -> IngestVolumeAccessTestResult {
        if let engine = inProcessEngine {
            return engine.testVolumeAccess(request: request)
        }

        guard let jsonString = IngestEngine.shared.serialize(request) else {
            throw NSError(domain: "IngestClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode VolumeAccessTestRequest"])
        }

        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.testVolumeAccess(requestJson: jsonString) { replyJson, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let replyJson = replyJson {
                    do {
                        let result = try IngestEngine.shared.deserialize(IngestVolumeAccessTestResult.self, from: replyJson)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty reply from service"]))
                }
            }
        }
    }

    public func ingest(
        slug: String,
        options: IngestOptions = .default,
        onProgress: (@Sendable (IngestProgressUpdate) -> Void)? = nil
    ) async throws -> IngestResult {
        guard let optionsJson = IngestEngine.shared.serialize(options) else {
            throw NSError(domain: "IngestClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode IngestOptions"])
        }

        let receiver: IngestProgressReceiver? = onProgress.map { IngestProgressReceiver(onProgress: $0) }
        let connection = makeConnection(progressReceiver: receiver)
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? GarageIngestXPCServiceProtocol else {
                continuation.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"]))
                return
            }

            proxy.ingestSource(slug: slug, optionsJson: optionsJson) { success, message in
                continuation.resume(returning: IngestResult(succeeded: success, message: message))
            }
        }
    }

    public func ingestStream(
        slug: String,
        options: IngestOptions = .default
    ) -> AsyncThrowingStream<IngestProgressUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.ingest(slug: slug, options: options) { progress in
                        continuation.yield(progress)
                    }
                    if !result.succeeded {
                        let errMsg = result.message ?? "Ingest failed"
                        continuation.finish(throwing: NSError(domain: "IngestClient", code: 500, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
