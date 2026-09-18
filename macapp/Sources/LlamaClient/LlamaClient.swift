import Foundation
import OSLog
import PythonXPCService_static

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "LlamaClient")

public enum LlamaClientError: LocalizedError {
    case serviceUnavailable(String)
    case serializationError(String)
    case serverError(statusCode: Int, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let msg):
            return "Llama XPC Service unavailable: \(msg)"
        case .serializationError(let msg):
            return "Serialization error: \(msg)"
        case .serverError(let code, let msg):
            return "Server error (\(code)): \(msg)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        }
    }
}

/// High-level Swift client for connecting to `LlamaXPCService` over macOS XPC or in-process.
public final class LlamaClient: @unchecked Sendable {
    private let connection: NSXPCConnection?
    private let inProcessEngine: LlamaServerEngine?
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    /// Initialize client connecting to the macOS XPC service.
    public init(serviceName: String = LlamaXPCConstants.serviceName) {
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.remoteObjectInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
        conn.resume()
        self.connection = conn
        self.inProcessEngine = nil
    }

    /// Initialize client with an existing NSXPCConnection.
    public init(connection: NSXPCConnection) {
        if connection.remoteObjectInterface == nil {
            connection.remoteObjectInterface = NSXPCInterface(with: LlamaXPCServiceProtocol.self)
        }
        self.connection = connection
        self.inProcessEngine = nil
    }

    /// Initialize client using an in-process LlamaServerEngine (ideal for testing or direct embedded use).
    public init(inProcessEngine: LlamaServerEngine) {
        self.connection = nil
        self.inProcessEngine = inProcessEngine
    }

    deinit {
        connection?.invalidate()
    }

    // MARK: - Relay & Remote Call Helper

    private final class ContinuationRelay<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }

    private func performRemoteCall<T>(
        _ block: @escaping (LlamaXPCServiceProtocol, ContinuationRelay<T>) -> Void
    ) async throws -> T {
        guard let conn = connection else {
            throw LlamaClientError.serviceUnavailable("No active NSXPCConnection")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let relay = ContinuationRelay(continuation)
            guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
                relay.resume(throwing: LlamaClientError.serviceUnavailable(error.localizedDescription))
            }) as? LlamaXPCServiceProtocol else {
                relay.resume(throwing: LlamaClientError.serviceUnavailable("Failed to acquire LlamaXPCServiceProtocol proxy"))
                return
            }

            let bundleRef = Bundle.main.bundleURL
            proxy.setAppBundleReference(bundleRef) { _, _ in
                block(proxy, relay)
            }
        }
    }

    // MARK: - Status & Info

    public func ping() async throws -> String {
        if inProcessEngine != nil {
            return "pong (in-process)"
        }
        do {
            return try await performRemoteCall { proxy, relay in
                proxy.ping { reply in
                    relay.resume(returning: reply)
                }
            }
        } catch {
            return "pong (in-process fallback)"
        }
    }

    public func health() async throws -> LlamaHealthResponse {
        if let engine = inProcessEngine {
            let dict = engine.handleHealth()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaHealthResponse.self, from: data)
        }
        do {
            return try await performRemoteCall { proxy, relay in
                proxy.health { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty health response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaHealthResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = LlamaServerEngine.shared.handleHealth()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaHealthResponse.self, from: data)
        }
    }

    public func props() async throws -> LlamaPropsResponse {
        if let engine = inProcessEngine {
            let dict = engine.handleProps()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaPropsResponse.self, from: data)
        }
        do {
            return try await performRemoteCall { proxy, relay in
                proxy.props { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty props response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaPropsResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = LlamaServerEngine.shared.handleProps()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaPropsResponse.self, from: data)
        }
    }

    public func listModels() async throws -> LlamaModelsResponse {
        if let engine = inProcessEngine {
            let dict = engine.handleModels()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaModelsResponse.self, from: data)
        }
        do {
            return try await performRemoteCall { proxy, relay in
                proxy.models { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty models response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaModelsResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = LlamaServerEngine.shared.handleModels()
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaModelsResponse.self, from: data)
        }
    }

    // MARK: - Completions

    public func complete(_ request: LlamaCompletionRequest) async throws -> LlamaCompletionResponse {
        let reqData = try jsonEncoder.encode(request)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaCompletionRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleCompletion(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaCompletionResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.completion(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty completion response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaCompletionResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleCompletion(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaCompletionResponse.self, from: data)
        }
    }

    public func complete(
        prompt: String,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        stop: [String]? = nil
    ) async throws -> LlamaCompletionResponse {
        let req = LlamaCompletionRequest(
            prompt: prompt,
            temperature: temperature,
            maxTokens: maxTokens,
            stop: stop
        )
        return try await complete(req)
    }

    // MARK: - Chat Completions

    public func chat(_ request: LlamaChatCompletionRequest) async throws -> LlamaChatCompletionResponse {
        let reqData = try jsonEncoder.encode(request)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaChatCompletionRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleChatCompletion(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaChatCompletionResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.chatCompletion(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty chat completion response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaChatCompletionResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleChatCompletion(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaChatCompletionResponse.self, from: data)
        }
    }

    public func chat(
        messages: [LlamaChatMessage],
        maxTokens: Int? = nil,
        temperature: Float? = nil
    ) async throws -> LlamaChatCompletionResponse {
        let req = LlamaChatCompletionRequest(
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens
        )
        return try await chat(req)
    }

    // MARK: - Embeddings

    public func embed(_ request: LlamaEmbeddingRequest) async throws -> LlamaEmbeddingResponse {
        let reqData = try jsonEncoder.encode(request)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaEmbeddingRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleEmbeddings(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaEmbeddingResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.embeddings(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty embeddings response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaEmbeddingResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleEmbeddings(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaEmbeddingResponse.self, from: data)
        }
    }

    public func embed(texts: [String], model: String? = nil, dimensions: Int? = nil) async throws -> [[Float]] {
        let req = LlamaEmbeddingRequest(input: texts, model: model, dimensions: dimensions)
        let resp = try await embed(req)
        return resp.data.map { $0.embedding }
    }

    // MARK: - Tokenize & Detokenize

    public func tokenize(
        content: String,
        addSpecial: Bool? = true,
        withPieces: Bool? = false
    ) async throws -> LlamaTokenizeResponse {
        let req = LlamaTokenizeRequest(content: content, addSpecial: addSpecial, withPieces: withPieces)
        let reqData = try jsonEncoder.encode(req)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaTokenizeRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleTokenize(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaTokenizeResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.tokenize(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty tokenize response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaTokenizeResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleTokenize(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaTokenizeResponse.self, from: data)
        }
    }

    public func detokenize(tokens: [Int]) async throws -> String {
        let req = LlamaDetokenizeRequest(tokens: tokens)
        let reqData = try jsonEncoder.encode(req)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaDetokenizeRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleDetokenize(jsonString: reqJson)
            return (dict["content"] as? String) ?? ""
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.detokenize(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty detokenize response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaDetokenizeResponse.self, from: data)
                        relay.resume(returning: resp.content)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleDetokenize(jsonString: reqJson)
            return (dict["content"] as? String) ?? ""
        }
    }

    // MARK: - Rerank

    public func rerank(
        query: String,
        documents: [String],
        topN: Int? = nil,
        model: String? = nil
    ) async throws -> LlamaRerankResponse {
        let req = LlamaRerankRequest(query: query, documents: documents, topN: topN, model: model)
        let reqData = try jsonEncoder.encode(req)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaRerankRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleRerank(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaRerankResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.rerank(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty rerank response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaRerankResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleRerank(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaRerankResponse.self, from: data)
        }
    }

    // MARK: - Infill

    public func infill(
        prefix: String,
        suffix: String,
        prompt: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> LlamaInfillResponse {
        let req = LlamaInfillRequest(inputPrefix: prefix, inputSuffix: suffix, prompt: prompt, nPredict: maxTokens)
        let reqData = try jsonEncoder.encode(req)
        guard let reqJson = String(data: reqData, encoding: .utf8) else {
            throw LlamaClientError.serializationError("Failed to encode LlamaInfillRequest")
        }

        if let engine = inProcessEngine {
            let dict = try engine.handleInfill(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaInfillResponse.self, from: data)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.infill(requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty infill response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaInfillResponse.self, from: data)
                        relay.resume(returning: resp)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = try LlamaServerEngine.shared.handleInfill(jsonString: reqJson)
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try jsonDecoder.decode(LlamaInfillResponse.self, from: data)
        }
    }

    // MARK: - Slots

    public func slots() async throws -> [LlamaSlot] {
        if let engine = inProcessEngine {
            let dict = engine.handleSlots()
            let data = try JSONSerialization.data(withJSONObject: dict)
            let resp = try jsonDecoder.decode(LlamaSlotsResponse.self, from: data)
            return resp.slots
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.slots { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json, let data = json.data(using: .utf8) else {
                        relay.resume(throwing: LlamaClientError.invalidResponse("Empty slots response"))
                        return
                    }
                    do {
                        let resp = try self.jsonDecoder.decode(LlamaSlotsResponse.self, from: data)
                        relay.resume(returning: resp.slots)
                    } catch {
                        relay.resume(throwing: error)
                    }
                }
            }
        } catch {
            let dict = LlamaServerEngine.shared.handleSlots()
            let data = try JSONSerialization.data(withJSONObject: dict)
            let resp = try jsonDecoder.decode(LlamaSlotsResponse.self, from: data)
            return resp.slots
        }
    }

    public func slotAction(
        slotId: Int,
        action: String,
        request: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let reqData = try JSONSerialization.data(withJSONObject: request ?? [:])
        let reqJson = String(data: reqData, encoding: .utf8) ?? "{}"

        if let engine = inProcessEngine {
            return try engine.handleSlotAction(slotId: slotId, action: action, jsonString: reqJson)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.slotAction(slotId: slotId, action: action, requestJson: reqJson) { json, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    guard let json = json,
                          let data = json.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        relay.resume(returning: ["status": "ok"])
                        return
                    }
                    relay.resume(returning: dict)
                }
            }
        } catch {
            return try LlamaServerEngine.shared.handleSlotAction(slotId: slotId, action: action, jsonString: reqJson)
        }
    }

    // MARK: - HTTP Replacement Generic Route Request

    public func handleServerRequest(
        endpoint: String,
        method: String = "POST",
        jsonBody: String? = nil
    ) async throws -> (statusCode: Int, responseBody: String) {
        if let engine = inProcessEngine {
            return engine.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.handleServerRequest(endpoint: endpoint, method: method, jsonBody: jsonBody) { statusCode, responseBody, errorMessage in
                    if statusCode >= 200 && statusCode < 300 {
                        relay.resume(returning: (statusCode, responseBody ?? "{}"))
                    } else {
                        let body = responseBody ?? (errorMessage != nil ? "{\"error\": \"\(errorMessage!)\"}" : "{}")
                        relay.resume(returning: (statusCode, body))
                    }
                }
            }
        } catch {
            return LlamaServerEngine.shared.handleRoute(endpoint: endpoint, method: method, jsonBody: jsonBody)
        }
    }

    // MARK: - Model Management

    public func loadModel(path: String, alias: String? = nil, config: [String: Any]? = nil) async throws -> String {
        var configJson: String? = nil
        if let config = config {
            let data = try JSONSerialization.data(withJSONObject: config)
            configJson = String(data: data, encoding: .utf8)
        }

        if let engine = inProcessEngine {
            let res = engine.loadModel(path: path, alias: alias, configJson: configJson)
            if res.success {
                return res.message
            } else {
                throw LlamaClientError.serverError(statusCode: 500, message: res.message)
            }
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.loadModel(modelPath: path, alias: alias, configJson: configJson) { success, msg, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    if success {
                        relay.resume(returning: msg ?? "Model loaded")
                    } else {
                        relay.resume(throwing: LlamaClientError.serverError(statusCode: 500, message: msg ?? "Failed to load model"))
                    }
                }
            }
        } catch {
            let res = LlamaServerEngine.shared.loadModel(path: path, alias: alias, configJson: configJson)
            if res.success {
                return res.message
            } else {
                throw LlamaClientError.serverError(statusCode: 500, message: res.message)
            }
        }
    }

    public func unloadModel() async throws -> Bool {
        if let engine = inProcessEngine {
            return engine.unloadModel()
        }

        do {
            return try await performRemoteCall { proxy, relay in
                proxy.unloadModel { success, error in
                    if let error = error {
                        relay.resume(throwing: error)
                        return
                    }
                    relay.resume(returning: success)
                }
            }
        } catch {
            return LlamaServerEngine.shared.unloadModel()
        }
    }
}
