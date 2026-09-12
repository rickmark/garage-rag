import Foundation

/// Objective-C protocol for receiving progress updates from GarageIngestXPCService across XPC.
@objc(GarageIngestProgressReceiverProtocol)
public protocol GarageIngestProgressReceiverProtocol: NSObjectProtocol {
    /// Receive JSON-serialized progress update.
    func didUpdateProgress(progressJson: String)
}

/// Objective-C protocol exposed by GarageIngestXPCService over NSXPC.
@objc(GarageIngestXPCServiceProtocol)
public protocol GarageIngestXPCServiceProtocol {
    /// Ping the service for health check.
    func ping(with reply: @escaping (String) -> Void)

    /// Ingest a source by slug (or "*") with JSON-serialized options.
    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void)

    /// Ingest a path directly with options dictionary (backwards compatibility).
    func ingestPath(_ path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void)

    /// Set root volume security-scoped bookmark data so the sandboxed XPC service can access the filesystem.
    func setRootVolumeBookmark(_ bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void)

    /// Set security-scoped bookmark data for a specific source directory.
    func setSourceBookmark(path: String, bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void)

    /// Revoke all active security-scoped volume and source access.
    func revokeAccess(with reply: @escaping (Bool) -> Void)

    /// Run full volume and source access tests inside the sandboxed XPC process.
    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void)
}

public enum IngestXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.ingest-xpc"
    public static let machServiceName = "me.rickmark.garage-rag.ingest-xpc"
}
