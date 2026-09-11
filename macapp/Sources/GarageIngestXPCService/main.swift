import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

@objc public protocol GarageIngestXPCServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
    func ingestPath(_ path: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void)
}

final class GarageIngestXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageIngestXPCServiceProtocol {
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
        _ = try? Python.attemptImport("garage_rag.ingest")
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        initializePythonIfNeeded()
        reply("pong from GarageIngestXPCService")
    }

    func ingestPath(_ source: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        #if canImport(PythonKit)
        do {
            let ingestModule = try Python.attemptImport("garage_rag.ingest")
            ingestModule.ingest_xpc(source)
            reply(true, "Ingest module loaded successfully: \(ingestModule)")
        } catch {
            reply(false, "Failed to load ingest module: \(error)")
        }
        #else
        reply(true, "Ingest completed without PythonKit")
        #endif
    }
}

let delegate = GarageIngestXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
