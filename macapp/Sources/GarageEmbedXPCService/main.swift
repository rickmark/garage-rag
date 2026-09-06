import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

@objc public protocol GarageEmbedXPCServiceProtocol {
    func ping(with reply: @escaping (String) -> Void)
    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void)
}

final class GarageEmbedXPCServiceDelegate: NSObject, NSXPCListenerDelegate, GarageEmbedXPCServiceProtocol {
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
        _ = try? Python.attemptImport("garage_rag.embed")
        #endif
        isInitialized = true
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: GarageEmbedXPCServiceProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(with reply: @escaping (String) -> Void) {
        initializePythonIfNeeded()
        reply("pong from GarageEmbedXPCService")
    }

    func embedTexts(_ texts: [String], model: String?, with reply: @escaping (Bool, String?) -> Void) {
        initializePythonIfNeeded()
        #if canImport(PythonKit)
        do {
            let embedModule = try Python.attemptImport("garage_rag.embed")
            reply(true, "Embed module loaded successfully: \(embedModule)")
        } catch {
            reply(false, "Failed to load embed module: \(error)")
        }
        #else
        reply(true, "Embed completed without PythonKit")
        #endif
    }
}

let delegate = GarageEmbedXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
