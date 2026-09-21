import Foundation
import Darwin
import OSLog
import LlamaClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.llama-xpc", category: "LlamaXPCService")

/// Wraps the in-process llama inference engine as a managed service so the host can (re)load / unload the
/// configured model. `start()` is a no-op until `loadModel` has configured a model path.
final class LlamaEngineManagedService: GarageManagedService {
    let name = "llama-engine"

    private let lock = NSLock()
    private let engine: LlamaServerEngine
    private var modelPath: String?
    private var alias: String?
    private var configJson: String?
    private var autoStart = false
    private(set) var lastMessage: String?

    init(engine: LlamaServerEngine) {
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

    var isConfigured: Bool {
        lock.lock(); defer { lock.unlock() }
        return autoStart
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
            logger.info("Model loaded successfully: \(res.message, privacy: .public)")
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

final class LlamaXPCServiceDelegate: GarageXPCServiceBase, LlamaXPCServiceProtocol {
    private let engine = LlamaServerEngine.shared
    private let engineService: LlamaEngineManagedService

    init() {
        engineService = LlamaEngineManagedService(engine: engine)
        super.init(
            serviceName: "LlamaXPCService",
            logFileName: "llama-xpc.log",
            usesPython: false
        )
    }

    override var exportedInterface: NSXPCInterface {
        NSXPCInterface(with: LlamaXPCServiceProtocol.self)
    }

    override func additionalSelfTests() -> [GarageXPCSelfTest] {
        let engine = self.engine
        return [
            GarageXPCSelfTest(name: "Llama Engine", description: "Queries the llama inference engine health endpoint and reports slot usage.", requiresPython: false) {
                let health = engine.handleHealth()
                guard let status = health["status"] as? String else {
                    throw GarageXPCSelfTestFailure("Llama engine health returned no status", details: String(describing: health))
                }
                let idle = health["slots_idle"] as? Int ?? 0
                let processing = health["slots_processing"] as? Int ?? 0
                let modelState = engine.currentModelPath != nil ? "model_loaded" : "idle"
                return "Status: \(status)\nEngine: \(modelState)\nModel: \(engine.currentModelPath ?? "none")\nSlots idle: \(idle), processing: \(processing)"
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
        ]
    }

    override func registerManagedServices(in host: GarageXPCServiceHost) {
        host.register(engineService)
    }

    // MARK: - LlamaXPCServiceProtocol

    func health(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleHealth()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func props(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleProps()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func models(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleModels()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func completion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling completion request")
            let dict = try engine.handleCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Completion request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func chatCompletion(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling chatCompletion request")
            let dict = try engine.handleChatCompletion(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Chat completion request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func embeddings(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling embeddings request")
            let dict = try engine.handleEmbeddings(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Embeddings request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func tokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling tokenize request")
            let dict = try engine.handleTokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Tokenize request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func detokenize(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling detokenize request")
            let dict = try engine.handleDetokenize(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Detokenize request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func rerank(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling rerank request")
            let dict = try engine.handleRerank(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Rerank request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func infill(requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling infill request")
            let dict = try engine.handleInfill(jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("Infill request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func slots(with reply: @escaping (String?, Error?) -> Void) {
        let dict = engine.handleSlots()
        let json = engine.serializeJson(dict)
        reply(json, nil)
    }

    func slotAction(slotId: Int, action: String, requestJson: String, with reply: @escaping (String?, Error?) -> Void) {
        do {
            logger.debug("Handling slotAction request: slotId=\(slotId), action=\(action, privacy: .public)")
            let dict = try engine.handleSlotAction(slotId: slotId, action: action, jsonString: requestJson)
            let json = engine.serializeJson(dict)
            reply(json, nil)
        } catch {
            logger.error("SlotAction request failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, error)
        }
    }

    func handleServerRequest(endpoint: String, method: String, jsonBody: String?, with reply: @escaping (Int, String?, String?) -> Void) {
        logger.debug("Handling server request: method=\(method, privacy: .public), endpoint=\(endpoint, privacy: .public)")
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
        host.stopAll(graceful: true) { [engineService] states in
            if case .failed(let message)? = states[engineService.name] {
                logger.error("Failed to unload model: \(message, privacy: .public)")
                reply(false, nil)
            } else {
                reply(true, nil)
            }
        }
    }
}

// MARK: - Process Entry Point

let delegate = LlamaXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
