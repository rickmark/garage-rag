import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

@objc public protocol GarageMCPServerServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
    func startServer(options: [String: String], with reply: @escaping (Bool, String?) -> Void)
}

final class GarageMCPServerServiceDelegate: NSObject, NSXPCListenerDelegate, GarageMCPServerServiceProtocol {
    private var isInitialized = false

    private func initializePythonIfNeeded() {
        guard !isInitialized else { return }
        #if canImport(PythonKit)
        let sys = Python.import("sys")
        if let resourceURL = Bundle.main.resourceURL {
            let parFile = resourceURL.appendingPathComponent("garage-par")
            if FileManager.default.fileExists(atPath: parFile.path) {
                sys.path.insert(0, parFile.path)
            }
            sys.path.insert(0, resourceURL.path)
        }
        _ = try? Python.attemptImport("garage_rag.mcp_server")
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageMCPServerServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        initializePythonIfNeeded()
        reply("pong from GarageMCPServerService")
    }

    func startServer(options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        #if canImport(PythonKit)
        do {
            let os = Python.import("os")
            for (key, value) in options {
                os.environ[key] = PythonObject(value)
            }
            if let dbURL = options["GARAGE_DATABASE_URL"] ?? options["database_url"] {
                os.environ["GARAGE_DATABASE_URL"] = PythonObject(dbURL)
            }
            let mcpModule = try Python.attemptImport("garage_rag.mcp_server")
            reply(true, "MCP server module loaded successfully: \(mcpModule)")
        } catch {
            reply(false, "Failed to load MCP server module: \(error)")
        }
        #else
        reply(true, "Started without PythonKit")
        #endif
    }
}

let delegate = GarageMCPServerServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
