import Foundation
import IngestClient
#if canImport(PythonKit)
import PythonKit
#endif

private typealias ProgressCFunction = @convention(c) (UnsafePointer<CChar>?) -> Void

private let globalProgressCallback: ProgressCFunction = { cStr in
    guard let cStr = cStr else { return }
    let jsonString = String(cString: cStr)
    GarageIngestXPCServiceDelegate.sharedActiveConnection?.remoteObjectProxyWithErrorHandler { _ in }
    if let receiver = GarageIngestXPCServiceDelegate.sharedActiveConnection?.remoteObjectProxy as? GarageIngestProgressReceiverProtocol {
        receiver.didUpdateProgress(progressJson: jsonString)
    }
}

final class GarageIngestXPCConnectionHandler: NSObject, GarageIngestXPCServiceProtocol {
    private let connection: NSXPCConnection
    private let engine = IngestEngine.shared
    private let parent: GarageIngestXPCServiceDelegate

    init(connection: NSXPCConnection, parent: GarageIngestXPCServiceDelegate) {
        self.connection = connection
        self.parent = parent
    }

    func ping(with reply: @escaping (String) -> Void) {
        parent.initializePythonIfNeeded()
        reply("pong from GarageIngestXPCService")
    }

    func setRootVolumeBookmark(_ bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        let result = engine.setRootVolumeBookmark(bookmarkData)
        reply(result.success, result.message)
    }

    func setSourceBookmark(path: String, bookmarkData: Data, with reply: @escaping (Bool, String?) -> Void) {
        let result = engine.setSourceBookmark(path: path, bookmarkData: bookmarkData)
        reply(result.success, result.message)
    }

    func revokeAccess(with reply: @escaping (Bool) -> Void) {
        engine.revokeAccess()
        reply(true)
    }

    func testVolumeAccess(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            let request = try engine.deserialize(VolumeAccessTestRequest.self, from: requestJson)
            let result = engine.testVolumeAccess(request: request)
            let responseJson = engine.serialize(result)
            reply(responseJson, nil)
        } catch {
            reply(nil, error)
        }
    }

    func ingestSource(slug: String, optionsJson: String, with reply: @escaping (Bool, String?) -> Void) {
        parent.initializePythonIfNeeded()
        let options = (try? engine.deserialize(IngestOptions.self, from: optionsJson)) ?? .default

        #if canImport(PythonKit)
        do {
            let ingestModule = try Python.attemptImport("garage_rag.ingest")

            GarageIngestXPCServiceDelegate.sharedActiveConnection = self.connection

            // Register C callback function pointer with Python
            let cFuncPtr = unsafeBitCast(globalProgressCallback, to: Int.self)
            ingestModule.set_c_progress_callback(cFuncPtr)
            defer {
                ingestModule.set_c_progress_callback(0)
                GarageIngestXPCServiceDelegate.sharedActiveConnection = nil
            }

            if ingestModule.run_ingest_xpc != Python.None {
                let limitObj: PythonObject = options.limit != nil ? PythonObject(options.limit!) : Python.None
                ingestModule.run_ingest_xpc(
                    slug,
                    include_code: options.includeCode,
                    limit: limitObj,
                    force: options.force
                )
            } else {
                let asyncio = Python.import("asyncio")
                let limitObj: PythonObject = options.limit != nil ? PythonObject(options.limit!) : Python.None
                let coro = ingestModule.ingest_xpc(
                    slug,
                    include_code: options.includeCode,
                    limit: limitObj,
                    force: options.force
                )
                asyncio.run(coro)
            }

            reply(true, "Ingestion completed successfully for \(slug)")
        } catch {
            reply(false, "Failed to run ingestion: \(error)")
        }
        #else
        reply(true, "Ingest completed (stub)")
        #endif
    }

    func ingestPath(_ source: String, options: [String: String], with reply: @escaping (Bool, String?) -> Void) {
        parent.initializePythonIfNeeded()
        #if canImport(PythonKit)
        do {
            let ingestModule = try Python.attemptImport("garage_rag.ingest")
            if ingestModule.run_ingest_xpc != Python.None {
                ingestModule.run_ingest_xpc(source)
            } else {
                let asyncio = Python.import("asyncio")
                let coro = ingestModule.ingest_xpc(source)
                asyncio.run(coro)
            }
            reply(true, "Ingest completed successfully for: \(source)")
        } catch {
            reply(false, "Failed to run ingest: \(error)")
        }
        #else
        reply(true, "Ingest completed (stub)")
        #endif
    }
}

final class GarageIngestXPCServiceDelegate: NSObject, NSXPCListenerDelegate {
    private var isInitialized = false
    static weak var sharedActiveConnection: NSXPCConnection?

    func initializePythonIfNeeded() {
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
        let handler = GarageIngestXPCConnectionHandler(connection: newConnection, parent: self)
        newConnection.exportedInterface = NSXPCInterface(with: GarageIngestXPCServiceProtocol.self)
        newConnection.exportedObject = handler
        newConnection.remoteObjectInterface = NSXPCInterface(with: GarageIngestProgressReceiverProtocol.self)
        newConnection.resume()
        return true
    }
}

let delegate = GarageIngestXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
