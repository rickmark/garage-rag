import Foundation
import Darwin
import OSLog
import LlamaClient
import LlamaEngine
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.llama-xpc", category: "LlamaXPCService")

/// Wraps the llama.cpp engine as a managed service so the host can (re)load / unload the configured
/// model. `start()` is a no-op until `loadModel` has configured a model path.
final class LlamaEngineManagedService: GarageManagedService {
    let name = "llama-engine"

    private let lock = NSLock()
    private let engine: LlamaCppEngine
    private var modelPath: String?
    private var alias: String?
    private var configJson: String?
    private var autoStart = false
    private(set) var lastMessage: String?

    init(engine: LlamaCppEngine) {
        self.engine = engine
    }

    /// Configures the model used by the next `start()`.
    func configure(modelPath: String, alias: String?, configJson: String?) {
        lock.lock()
        self.modelPath = modelPath
        self.alias = alias
        self.configJson = configJson
        self.autoStart = true
        lock.unlock()
    }

    /// Forgets the configured model so a later restart does not reload it.
    func clearConfiguration() {
        lock.lock()
        modelPath = nil
        alias = nil
        configJson = nil
        autoStart = false
        lock.unlock()
    }

    var isRunning: Bool {
        engine.currentModelPath != nil
    }

    func start() throws {
        lock.lock()
        let shouldStart = autoStart
        let (path, alias, configJson) = (modelPath, self.alias, self.configJson)
        lock.unlock()
        guard shouldStart, let path = path else {
            logger.info("llama-engine not configured yet; waiting for loadModel")
            return
        }

        let res = engine.loadModel(path: path, alias: alias, configJson: configJson)
        lock.lock()
        lastMessage = res.message
        lock.unlock()
        if res.success {
            logger.info("Model loaded: \(res.message, privacy: .public)")
            GarageXPCOutputCapture.shared.log(message: "llama-engine loaded model \(path)")
        } else {
            logger.error("Failed to load model: \(res.message, privacy: .public)")
            throw GarageXPCServiceError.notRunning(res.message)
        }
    }

    func stop(graceful: Bool) throws {
        guard engine.currentModelPath != nil else { return }
        let ok = engine.unloadModel()
        if !ok {
            throw GarageXPCServiceError.notRunning("llama-engine failed to unload the current model")
        }
        logger.info("llama-engine unloaded model (graceful: \(graceful, privacy: .public))")
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
        engineService.configure(modelPath: modelPath, alias: alias, configJson: configJson)
        host.restart(named: engineService.name, graceful: true) { [engineService] state in
            switch state {
            case .running:
                reply(true, engineService.lastMessage ?? "Model loaded successfully from \(modelPath)", nil)
            case .failed(let message):
                reply(false, message, nil)
            default:
                reply(false, "llama-engine is \(state.name)", nil)
            }
        }
    }

    func unloadModel(with reply: @escaping (Bool, Error?) -> Void) {
        logger.info("Unloading current model")
        engineService.clearConfiguration()
        guard engineService.isRunning else {
            reply(true, nil)
            return
        }
        host.restart(named: engineService.name, graceful: true) { [engineService] state in
            // With no configuration, restart stops the engine and start() becomes a no-op.
            if case .failed(let message) = state {
                logger.error("Failed to unload model: \(message, privacy: .public)")
                reply(false, nil)
            } else {
                reply(!engineService.isRunning, nil)
            }
        }
    }
}

// MARK: - Process Entry Point

let delegate = LlamaXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
