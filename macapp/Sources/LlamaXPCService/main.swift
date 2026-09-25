import Foundation
import Darwin
import OSLog
import LlamaClient
import LlamaEngine
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.llama-xpc", category: "LlamaXPCService")

/// Presents the llama.cpp engine to the host as a managed service. Models are loaded and unloaded
/// directly through the XPC/HTTP routes (several can be resident at once), so `start()` has nothing
/// to do and `stop()` simply unloads everything at shutdown.
final class LlamaEngineManagedService: GarageManagedService {
    let name = "llama-engine"
    private let engine: LlamaCppEngine

    init(engine: LlamaCppEngine) {
        self.engine = engine
    }

    var isRunning: Bool {
        engine.currentModelPath != nil
    }

    func start() throws {
        let aliases = engine.loadedAliases
        if aliases.isEmpty {
            logger.info("llama-engine ready; no model loaded yet")
        } else {
            logger.info("llama-engine ready with \(aliases.joined(separator: ", "), privacy: .public)")
        }
    }

    func stop(graceful: Bool) throws {
        guard engine.currentModelPath != nil else { return }
        _ = engine.unloadModel()
        logger.info("llama-engine unloaded all models (graceful: \(graceful, privacy: .public))")
    }
}

/// The loopback HTTP listener as a managed service: up for the lifetime of the helper, independent
/// of whether a model is loaded (so `/health` can say "no_model_loaded"). The Python `llama_xpc`
/// provider talks to this port; the app keeps using XPC.
final class LlamaHTTPManagedService: GarageManagedService {
    let name = "llama-http"
    let server: LlamaHTTPServer

    init(server: LlamaHTTPServer) {
        self.server = server
    }

    var isRunning: Bool { server.isListening }

    func start() throws {
        do {
            try server.start()
        } catch {
            throw GarageXPCServiceError.notRunning(error.localizedDescription)
        }
        logger.info("llama HTTP API listening on \(self.server.url, privacy: .public)")
        GarageXPCOutputCapture.shared.log(message: "llama HTTP API listening on \(server.url)")
    }

    func stop(graceful: Bool) throws {
        server.stop()
    }
}

final class LlamaXPCServiceDelegate: GarageXPCServiceBase, LlamaXPCServiceProtocol {
    private let engine: LlamaCppEngine
    private let engineService: LlamaEngineManagedService
    private let httpService: LlamaHTTPManagedService

    init() {
        let engine = LlamaCppEngine()
        let server = LlamaHTTPServer(engine: engine, port: LlamaXPCServiceDelegate.configuredHTTPPort())
        engine.httpURL = server.url
        self.engine = engine
        self.engineService = LlamaEngineManagedService(engine: engine)
        self.httpService = LlamaHTTPManagedService(server: server)
        super.init(
            serviceName: "LlamaXPCService",
            logFileName: "llama-xpc.log",
            usesPython: false
        )
    }

    /// `GARAGE_LLAMA_HTTP_PORT` overrides the default so two builds can coexist on one machine.
    private static func configuredHTTPPort() -> UInt16 {
        if let raw = ProcessInfo.processInfo.environment["GARAGE_LLAMA_HTTP_PORT"], let port = UInt16(raw), port > 0 {
            return port
        }
        return LlamaXPCConstants.defaultHTTPPort
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: LlamaXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        let engine = self.engine
        let server = self.httpService.server
        return [
            GarageXPCSelfTest(name: "Llama Engine", description: "Queries the llama.cpp engine health route and reports the loaded model.", requiresPython: false) {
                let health = engine.handleHealth()
                guard let status = health["status"] as? String else {
                    throw GarageXPCSelfTestFailure("Llama engine health returned no status", details: String(describing: health))
                }
                let props = engine.handleProps()
                let model = engine.currentModelPath ?? "none"
                let desc = (props["model_description"] as? String) ?? ""
                return "Status: \(status)\nModel: \(model)\n\(desc)"
            },
            GarageXPCSelfTest(name: "Model File", description: "Verifies the currently loaded model path exists on disk.", requiresPython: false) {
                guard let path = engine.currentModelPath else {
                    throw GarageXPCSelfTestSkipped("No model loaded")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw GarageXPCSelfTestFailure("Loaded model file is missing: \(path)")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                return "Model: \(path)\nSize: \(size) bytes"
            },
            GarageXPCSelfTest(name: "HTTP API", description: "Reports whether the loopback llama-server API is listening.", requiresPython: false) {
                guard server.isListening else {
                    throw GarageXPCSelfTestFailure("llama HTTP API is not listening on \(server.url)")
                }
                return "Listening on \(server.url)"
            },
        ]
    }

    override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(httpService)
        host.register(engineService)
    }

    // MARK: - LlamaXPCServiceProtocol

    private func reply(_ route: String, _ reply: @escaping (String?, Error?) -> Void, _ body: () throws -> [String: Any]) {
        do {
            reply(engine.serializeJson(try body()), nil)
        } catch {
            logger.error("\(route, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func health(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleHealth()), nil)
    }

    func props(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleProps()), nil)
    }

    func models(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleModels()), nil)
    }

    func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("completion", reply) { try engine.handleCompletion(jsonString: requestJson) }
    }

    func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("chatCompletion", reply) { try engine.handleChatCompletion(jsonString: requestJson) }
    }

    func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("embeddings", reply) { try engine.handleEmbeddings(jsonString: requestJson) }
    }

    func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("tokenize", reply) { try engine.handleTokenize(jsonString: requestJson) }
    }

    func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("detokenize", reply) { try engine.handleDetokenize(jsonString: requestJson) }
    }

    func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("rerank", reply) { try engine.handleRerank(jsonString: requestJson) }
    }

    func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("infill", reply) { try engine.handleInfill(jsonString: requestJson) }
    }

    func slots(with reply: @escaping (String?, Error?) -> Void) {
        reply(engine.serializeJson(engine.handleSlots()), nil)
    }

    func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        self.reply("slotAction", reply) { try engine.handleSlotAction(slotId: slotId, action: action, jsonString: requestJson) }
    }

    func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void) {
        let result = engine.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        reply(result.statusCode, result.responseBody, nil)
    }

    func loadModel(modelPath: String, alias: String?, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        logger.info("Loading model from path: \(modelPath, privacy: .public), alias: \(alias ?? "none", privacy: .public)")
        // Loading blocks for seconds; keep the XPC thread free and answer when llama.cpp is done.
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            let result = engine.loadModel(path: modelPath, alias: alias, configJson: configJson)
            if result.success {
                GarageXPCOutputCapture.shared.log(message: "llama-engine loaded \(modelPath)")
            } else {
                logger.error("Failed to load model: \(result.message, privacy: .public)")
            }
            reply(result.success, result.message, nil)
        }
    }

    func ensureModel(modelPath: String, alias: String, configJson: String?, with reply: @escaping (Bool, String?, Error?) -> Void) {
        logger.info("Ensuring model \(alias, privacy: .public) (\(modelPath, privacy: .public))")
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            let alreadyLoaded = engine.loadedAliases.contains(alias)
            let result = engine.ensureModel(path: modelPath, alias: alias, configJson: configJson)
            if !result.success {
                logger.error("Failed to load model on demand: \(result.message, privacy: .public)")
            } else if !alreadyLoaded {
                GarageXPCOutputCapture.shared.log(message: "llama-engine loaded \(alias) on demand from \(modelPath)")
            }
            reply(result.success, result.message, nil)
        }
    }

    func unloadModel(with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Unloading all models")
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            reply(engine.unloadModel(), nil)
        }
    }
}

// MARK: - Process Entry Point

let delegate = LlamaXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
