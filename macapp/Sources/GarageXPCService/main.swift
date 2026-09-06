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
        initializePythonIfNeeded()
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
