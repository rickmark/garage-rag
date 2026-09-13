import Foundation
import Darwin
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

    private func setupPostgresEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            _ = dlopen(envPath, RTLD_NOW | RTLD_GLOBAL)
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.dylib").path)
            candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.5.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib").path)

        let grandParentURL = parentAppURL.deletingLastPathComponent()
        candidatePaths.append(grandParentURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(grandParentURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)

        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                setenv("GARAGE_LIBPQ_PATH", path, 1)
                let libDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
                setenv("DYLD_FALLBACK_LIBRARY_PATH", libDir, 1)
                _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
                break
            }
        }
    }

    private func setupPythonEnvironment() {
        if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
           FileManager.default.fileExists(atPath: envPath) {
            return
        }

        var candidatePaths: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Versions/Current/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("python_3_13/Python.framework/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/Current/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(resourceURL.appendingPathComponent("Python.framework/Python").path)
        }
        if let fwURL = Bundle.main.privateFrameworksURL {
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/Current/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(fwURL.appendingPathComponent("Python.framework/Python").path)
        }

        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Frameworks/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Contents/Resources/python_3_13/Python.framework/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppURL.appendingPathComponent("Resources/python_3_13/Python.framework/Python").path)

        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/Current/Python")
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
        setupPostgresEnvironment()
        setupPythonEnvironment()
        #if canImport(PythonKit)
        try? PythonLibrary.loadLibrary()
        let sys = Python.import("sys")
        let parentAppURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()

        let pythonLibCandidates: [URL?] = [
            parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            Bundle.main.resourceURL?.appendingPathComponent("python_3_13/Python.framework/Versions/Current/lib/python3.13"),
            Bundle.main.resourceURL?.appendingPathComponent("python_3_13/Python.framework/Versions/3.13/lib/python3.13"),
        ]
        for libURL in pythonLibCandidates {
            if let libURL = libURL, FileManager.default.fileExists(atPath: libURL.path) {
                sys.path.insert(0, libURL.path)
            }
        }

        let sitePackagesCandidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("site-packages"),
            parentAppURL.appendingPathComponent("Contents/Resources/site-packages"),
            parentAppURL.appendingPathComponent("Resources/site-packages"),
            parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            parentAppURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            parentAppURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
        ]
        for spURL in sitePackagesCandidates {
            if let spURL = spURL, FileManager.default.fileExists(atPath: spURL.path) {
                sys.path.insert(0, spURL.path)
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
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
