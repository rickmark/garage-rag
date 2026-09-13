import Foundation
import OSLog

private let logger = Logger(subsystem: "me.rickmark.garage", category: "IngestClient")

/// Progress receiver adapter for XPC callbacks.
private final class IngestProgressReceiver: NSObject, GarageIngestProgressReceiverProtocol {
    private let onProgress: @Sendable (IngestProgressUpdate) -> Void
    private let engine = IngestEngine.shared

    init(onProgress: @escaping @Sendable (IngestProgressUpdate) -> Void) {
        self.onProgress = onProgress
    }

    func didUpdateProgress(progressJson: String) {
        if let update = try? engine.deserialize(IngestProgressUpdate.self, from: progressJson) {
            logger.debug("IngestProgressReceiver received update: phase=\(update.phase, privacy: .public), seen=\(update.seen)/\(update.totalItems), msg=\(update.message, privacy: .public)")
            onProgress(update)
        } else {
            logger.warning("IngestProgressReceiver failed to decode progress JSON: \(progressJson, privacy: .public)")
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
        logger.debug("Creating NSXPCConnection to service '\(name, privacy: .public)'")
        let connection = NSXPCConnection(serviceName: name)
        connection.remoteObjectInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)

        if let receiver = progressReceiver {
            connection.exportedInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)
            connection.exportedObject = receiver
        }

        connection.interruptionHandler = {
            let report = XPCDyldDiagnostics.diagnoseService(bundleId: name)
            logger.warning("IngestClient NSXPCConnection to '\(name, privacy: .public)' was interrupted. Diagnostics: \(report.shortSummary, privacy: .public)")
        }
        connection.invalidationHandler = {
            let report = XPCDyldDiagnostics.diagnoseService(bundleId: name)
            logger.info("IngestClient NSXPCConnection to '\(name, privacy: .public)' was invalidated. Diagnostics: \(report.shortSummary, privacy: .public)")
        }

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
        progressReceiver: GarageIngestProgressReceiverProtocol? = nil,
        _ block: @escaping (GarageIngestXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        let connection = makeConnection(progressReceiver: progressReceiver)
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                let enrichedError = XPCDyldDiagnostics.enrichXPCError(error, forServiceBundleId: self.customServiceName ?? IngestClient.serviceName)
                logger.error("XPC remote object proxy error for service '\(self.customServiceName ?? IngestClient.serviceName, privacy: .public)': \(enrichedError.localizedDescription, privacy: .public)")
                relay.resume(throwing: enrichedError)
            }) as? GarageIngestXPCServiceProtocol else {
                let err = NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XPC proxy"])
                let enrichedError = XPCDyldDiagnostics.enrichXPCError(err, forServiceBundleId: self.customServiceName ?? IngestClient.serviceName)
                logger.error("\(enrichedError.localizedDescription, privacy: .public)")
                relay.resume(throwing: enrichedError)
                return
            }

            block(proxy, relay)
        }
    }

    // MARK: - API Methods

    public func ping() async throws -> String {
        if let engine = inProcessEngine {
            _ = engine
            logger.info("ping: returning in-process IngestEngine response")
            return "pong from in-process IngestEngine"
        }

        do {
            logger.info("ping: dispatching remote XPC ping")
            return try await performRemoteCall { proxy, relay in
                proxy.ping { reply in
                    relay.resume(returning: reply)
                }
            }
        } catch {
            logger.warning("ping XPC failed: \(error.localizedDescription, privacy: .public), returning fallback")
            return "pong (in-process fallback)"
        }
    }

    public func setRootVolumeBookmark(_ bookmarkData: Data) async throws -> Bool {
        if let engine = inProcessEngine {
            logger.info("setRootVolumeBookmark: executing via in-process IngestEngine")
            return engine.setRootVolumeBookmark(bookmarkData).success
        }

        do {
            logger.info("setRootVolumeBookmark: dispatching via XPC (\(bookmarkData.count) bytes)")
            return try await performRemoteCall { proxy, relay in
                proxy.setRootVolumeBookmark(bookmarkData) { success, _ in
                    relay.resume(returning: success)
                }
            }
        } catch {
            logger.warning("setRootVolumeBookmark XPC failed: \(error.localizedDescription, privacy: .public), falling back to IngestEngine.shared")
            return IngestEngine.shared.setRootVolumeBookmark(bookmarkData).success
        }
    }

    public func setSourceBookmark(path: String, bookmarkData: Data) async throws -> Bool {
        if let engine = inProcessEngine {
            logger.info("setSourceBookmark: executing via in-process IngestEngine for '\(path, privacy: .public)'")
            return engine.setSourceBookmark(path: path, bookmarkData: bookmarkData).success
        }

        do {
            logger.info("setSourceBookmark: dispatching via XPC for '\(path, privacy: .public)' (\(bookmarkData.count) bytes)")
            return try await performRemoteCall { proxy, relay in
                proxy.setSourceBookmark(path: path, bookmarkData: bookmarkData) { success, _ in
                    relay.resume(returning: success)
                }
            }
        } catch {
            logger.warning("setSourceBookmark XPC failed for '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public), falling back to IngestEngine.shared")
            return IngestEngine.shared.setSourceBookmark(path: path, bookmarkData: bookmarkData).success
        }
    }

    public func revokeAccess() async throws -> Bool {
        if let engine = inProcessEngine {
            logger.info("revokeAccess: executing via in-process IngestEngine")
            engine.revokeAccess()
            return true
        }

        do {
            logger.info("revokeAccess: dispatching via XPC")
            return try await performRemoteCall { proxy, relay in
                proxy.revokeAccess { success in
                    relay.resume(returning: success)
                }
            }
        } catch {
            logger.warning("revokeAccess XPC failed: \(error.localizedDescription, privacy: .public), falling back to IngestEngine.shared")
            IngestEngine.shared.revokeAccess()
            return true
        }
    }

    public func cancelIngest() async throws -> Bool {
        if let engine = inProcessEngine {
            logger.info("cancelIngest: executing via in-process IngestEngine")
            engine.cancel()
            return true
        }

        do {
            logger.info("cancelIngest: dispatching via XPC")
            return try await performRemoteCall { proxy, relay in
                proxy.cancelIngest { success in
                    relay.resume(returning: success)
                }
            }
        } catch {
            logger.warning("cancelIngest XPC failed: \(error.localizedDescription, privacy: .public), cancelling IngestEngine.shared")
            IngestEngine.shared.cancel()
            return true
        }
    }

    public func testVolumeAccess(request: VolumeAccessTestRequest) async throws -> IngestVolumeAccessTestResult {
        if let engine = inProcessEngine {
            logger.info("testVolumeAccess: executing via in-process IngestEngine")
            return engine.testVolumeAccess(request: request)
        }

        guard let jsonString = IngestEngine.shared.serialize(request) else {
            let err = NSError(domain: "IngestClient", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to encode VolumeAccessTestRequest"])
            logger.error("\(err.localizedDescription, privacy: .public)")
            throw err
        }

        do {
            logger.info("testVolumeAccess: dispatching via XPC")
            return try await performRemoteCall { proxy, relay in
                proxy.testVolumeAccess(requestJson: jsonString) { replyJson, error in
                    if let error = error {
                        relay.resume(throwing: error)
                    } else if let replyJson = replyJson {
                        do {
                            let result = try IngestEngine.shared.deserialize(IngestVolumeAccessTestResult.self, from: replyJson)
                            relay.resume(returning: result)
                        } catch {
                            relay.resume(throwing: error)
                        }
                    } else {
                        relay.resume(throwing: NSError(domain: "IngestClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty reply from service"]))
                    }
                }
            }
        } catch {
            logger.warning("testVolumeAccess XPC failed: \(error.localizedDescription, privacy: .public), falling back to IngestEngine.shared")
            return IngestEngine.shared.testVolumeAccess(request: request)
        }
    }

    public func ingest(
        slug: String,
        options: IngestOptions = .default,
        onProgress: (@Sendable (IngestProgressUpdate) -> Void)? = nil
    ) async throws -> IngestResult {
        logger.info("IngestClient.ingest called for slug '\(slug, privacy: .public)' (includeCode: \(options.includeCode), force: \(options.force), limit: \(String(describing: options.limit)))")
        if let engine = inProcessEngine {
            logger.info("Executing ingestion via configured in-process engine for '\(slug, privacy: .public)'")
            return engine.ingestSource(slug: slug, options: options, onProgress: onProgress)
        }

        guard let optionsJson = IngestEngine.shared.serialize(options) else {
            let errorMsg = "Failed to encode IngestOptions for \(slug)"
            logger.error("\(errorMsg, privacy: .public)")
            onProgress?(IngestProgressUpdate(
                source: slug,
                phase: "error",
                message: errorMsg,
                error: errorMsg
            ))
            return IngestResult(succeeded: false, message: errorMsg)
        }

        let receiver: IngestProgressReceiver? = onProgress.map { IngestProgressReceiver(onProgress: $0) }

        do {
            logger.info("Dispatching ingestSource via XPC for '\(slug, privacy: .public)'")
            let result = try await performRemoteCall(progressReceiver: receiver) { proxy, relay in
                proxy.ingestSource(slug: slug, optionsJson: optionsJson) { success, message in
                    relay.resume(returning: IngestResult(succeeded: success, message: message))
                }
            }
            logger.info("IngestSource XPC reply for '\(slug, privacy: .public)': succeeded=\(result.succeeded), message=\(result.message ?? "nil", privacy: .public)")
            if !result.succeeded, let message = result.message {
                onProgress?(IngestProgressUpdate(
                    source: slug,
                    phase: "error",
                    message: message,
                    error: message
                ))
            }
            return result
        } catch {
            // Log the XPC failure to the progress stream and fallback to in-process execution
            let fallbackWarning = "XPC helper unavailable (\(error.localizedDescription)). Falling back to in-process execution for '\(slug)'..."
            logger.warning("\(fallbackWarning, privacy: .public)")
            onProgress?(IngestProgressUpdate(
                source: slug,
                phase: "scan",
                message: fallbackWarning
            ))

            let fallbackResult = IngestEngine.shared.ingestSource(slug: slug, options: options, onProgress: onProgress)
            logger.info("In-process fallback result for '\(slug, privacy: .public)': succeeded=\(fallbackResult.succeeded), message=\(fallbackResult.message ?? "nil", privacy: .public)")
            return fallbackResult
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
