import Foundation

/// Objective-C protocol for bidirectional / client-side log and output streaming from XPC services.
@objc(GarageXPCLogReceiverProtocol)
public protocol GarageXPCLogReceiverProtocol: NSObjectProtocol {
    /// Receive streaming stdout output chunk.
    func didReceiveStdout(_ text: String)
    /// Receive streaming stderr output chunk.
    func didReceiveStderr(_ text: String)
    /// Receive structured log entry.
    func didReceiveLog(source: String, level: String, message: String, timestamp: Double)
}

/// Common Objective-C protocol that all Garage XPC services inherit.
/// Provides standardized ping, service information, stdout/stderr log retrieval, and gRPC dispatch over XPC.
@objc(GarageCommonXPCServiceProtocol)
public protocol GarageCommonXPCServiceProtocol: NSObjectProtocol {
    /// Health check / ping returning service identifier and status message.
    func ping(with reply: @escaping (String) -> Void)

    /// Health check returning structured status (service name, PID, uptime/timestamp, extra status string).
    func getServiceInfo(with reply: @escaping (String, Int32, Double, String?) -> Void)

    /// Fetch buffered stdout and stderr strings since last fetch or since service startup.
    func fetchLogs(with reply: @escaping (String?, String?) -> Void)

    /// Fetch buffered stdout and stderr with option to clear buffer.
    func fetchBufferedOutput(clearBuffer: Bool, with reply: @escaping (String?, String?, Error?) -> Void)

    /// Clear in-memory log and output buffers.
    func clearLogs(with reply: @escaping (Bool) -> Void)

    /// Common gRPC invocation over XPC: dispatch a gRPC/protobuf call by service/method name with raw payload data.
    func handleGRPCCall(service: String, method: String, payload: Data, with reply: @escaping (Data?, String?, Error?) -> Void)

    /// Common gRPC JSON / text invocation over XPC: dispatch an RPC call by method name with JSON request string.
    func handleRPC(method: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void)
}
