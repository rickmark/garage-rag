import Foundation

/// Objective-C protocol matching the standard `ping` method implemented across all Garage XPC services.
@objc(GarageGenericXPCPingProtocol)
public protocol GarageGenericXPCPingProtocol: NSObjectProtocol {
    func ping(with reply: @escaping (String) -> Void)
}

/// Objective-C protocol for receiving progress updates from GarageIngestXPCService across XPC.
@objc(GarageIngestProgressReceiverProtocol)
public protocol GarageIngestProgressReceiverProtocol: NSObjectProtocol {
    /// Receive JSON-serialized progress update.
    func didUpdateProgress(progressJson: String)
}

/// Objective-C protocol exposed by GarageIngestXPCService over NSXPC.
@objc(GarageIngestXPCServiceProtocol)
public protocol GarageIngestXPCServiceProtocol: GarageCommonXPCServiceProtocol {
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

    /// Cancel any active ingestion in progress.
    func cancelIngest(with reply: @escaping (Bool) -> Void)

    /// Run full volume and source access tests inside the sandboxed XPC process.
    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void)

    /// Configure database URL and environment options for XPC ingestion.
    func configureEnvironment(databaseUrl: String?, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void)

    /// Set database URL and optional LM Studio API token via XPC.
    func setDatabaseURL(_ databaseUrl: String, lmStudioApiToken: String?, with reply: @escaping (Bool, String?) -> Void)
}

/// Objective-C protocol for Embed XPC Service communication.
@objc(GarageEmbedXPCServiceProtocol)
public protocol GarageEmbedXPCServiceProtocol: GarageCommonXPCServiceProtocol {
    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void)
    func embedBatches(model: String?, limit: Int, batchSize: Int, grpcHost: String?, grpcPort: Int, with reply: @escaping (Bool, String?) -> Void)
}

/// Objective-C protocol for MCP Server XPC Service communication.
@objc(GarageMCPServerServiceProtocol)
public protocol GarageMCPServerServiceProtocol: GarageCommonXPCServiceProtocol {
    func startServer(options: [String: String], with reply: @escaping (Bool, String?) -> Void)
}

/// Objective-C protocol for Garage Core Backend XPC Service communication.
@objc(GarageXPCServiceProtocol)
public protocol GarageXPCServiceProtocol: GarageCommonXPCServiceProtocol {
    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void)
}

public enum IngestXPCConstants {
    public static let serviceName = "me.rickmark.garage-rag.ingest-xpc"
    public static let machServiceName = "me.rickmark.garage-rag.ingest-xpc"
}
