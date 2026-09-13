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
    private let initLock = NSLock()

    private func setupPythonEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
           FileManager.default.fileExists(atPath: envPath) {
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_14/Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_14/Python.framework/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Python").path)
        }
        if let fwURL = Bundle.main.privateFrameworksURL {
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/3.14/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Python").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_14/Python.framework/Versions/3.14/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_14/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.14/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Python").path)

        candidatePaths.append("/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.12/Frameworks/Python.framework/Versions/3.12/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/usr/local/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.14/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.13/Python")

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                setenv("PYTHON_LIBRARY", path, 1)
                break
            }
        }
    }

    private func initializePythonIfNeeded() {
        initLock.lock()
        defer { initLock.unlock() }
        guard !isInitialized else { return }
        setupPythonEnvironment()
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
RunLoop.main.run()
