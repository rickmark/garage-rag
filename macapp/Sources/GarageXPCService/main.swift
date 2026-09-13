import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

@objc public protocol GarageXPCServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void)
}

final class GarageXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageXPCServiceProtocol {
    private var isInitialized = false
    private let initLock = NSLock()

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
        _ = try? Python.attemptImport("garage_rag.service")
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        reply("pong from GarageXPCService")
    }

    func executeCommand(_ command: String, arguments: [String], with reply: @escaping (Int32, String?, String?) -> Void) {
        initializePythonIfNeeded()
        #if canImport(PythonKit)
        do {
            let serviceModule = try Python.attemptImport("garage_rag.service")
            reply(0, "Service module loaded successfully: \(serviceModule)", nil)
        } catch {
            reply(1, nil, "Failed to load service module: \(error)")
        }
        #else
        reply(0, "Executed without PythonKit", nil)
        #endif
    }
}

let delegate = GarageXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
