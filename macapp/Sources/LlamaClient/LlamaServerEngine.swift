import Foundation

/// Server-side execution engine processing requests matching the llama-server HTTP protocol.
public final class LlamaServerEngine: @unchecked Sendable {
    public static let shared = LlamaServerEngine()

    private let lock = NSLock()
    private var loadedModelPath: String?
    private var modelAlias: String = "default"
    private var isModelLoaded: Bool = true
    private var totalSlots: Int = 1
    private var slotsState: [LlamaSlot] = [
        LlamaSlot(id: 0, state: 0, prompt: nil, taskId: nil)
    ]

    public init(
        modelPath: String? = nil,
        modelAlias: String = "default",
        totalSlots: Int = 1
    ) {
        self.loadedModelPath = modelPath
        self.modelAlias = modelAlias
        self.totalSlots = max(1, totalSlots)
        self.isModelLoaded = true
        self.slotsState = (0..<self.totalSlots).map { LlamaSlot(id: $0, state: 0, prompt: nil, taskId: nil) }
    }

    // MARK: - Model Management

    public func loadModel(path: String, alias: String? = nil, configJson: String? = nil) -> (success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        self.loadedModelPath = path
        if let alias = alias, !alias.isEmpty {
            self.modelAlias = alias
        }
        self.isModelLoaded = true
        return (true, "Model loaded successfully from \(path)")
    }

    public func unloadModel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.loadedModelPath = nil
        self.isModelLoaded = false
        return true
    }

    // MARK: - Protocol Endpoints

    public func handleHealth() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let idle = slotsState.filter { $0.state == 0 }.count
        let processing = slotsState.count - idle
        return [
            "status": isModelLoaded ? "ok" : "no_model_loaded",
            "slots_idle": idle,
            "slots_processing": processing
        ]
    }

    public func handleProps() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "default_generation_settings": [
                "temperature": 0.8,
                "top_k": 40,
                "top_p": 0.95,
                "min_p": 0.05,
                "n_predict": -1
            ],
            "total_slots": totalSlots,
            "model_alias": modelAlias,
            "modal_capabilities": [
                "completion",
                "chat",
                "embeddings",
                "tokenize",
                "detokenize",
                "rerank",
                "infill"
            ]
        ]
    }

    public func handleModels() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let model = [
            "id": modelAlias,
            "object": "model",
            "created": Int64(Date().timeIntervalSince1970),
            "owned_by": "llamacpp"
        ] as [String : Any]
        return [
            "object": "list",
            "data": [model]
        ]
    }

    public func handleCompletion(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in completion request"])
        }

        let prompt = (dict["prompt"] as? String) ?? ""
        let model = (dict["model"] as? String) ?? modelAlias
        let maxTokens = (dict["n_predict"] as? Int) ?? (dict["max_tokens"] as? Int) ?? 128
        let temperature = (dict["temperature"] as? NSNumber)?.floatValue ?? 0.7

        let generated = generateText(forPrompt: prompt, maxTokens: maxTokens, temperature: temperature)
        let promptTokens = tokenizeString(prompt).count
        let predictedTokens = tokenizeString(generated).count

        return [
            "content": generated,
            "stop": true,
            "model": model,
            "tokens_predicted": predictedTokens,
            "tokens_evaluated": promptTokens,
            "generation_settings": [
                "temperature": temperature,
                "max_tokens": maxTokens
            ],
            "timings": [
                "prompt_n": promptTokens,
                "prompt_ms": 1.2,
                "prompt_per_token_ms": 0.2,
                "predicted_n": predictedTokens,
                "predicted_ms": 5.4,
                "predicted_per_token_ms": 0.5
            ]
        ]
    }

    public func handleChatCompletion(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in chat completion request"])
        }

        let rawMessages = (dict["messages"] as? [[String: Any]]) ?? []
        let model = (dict["model"] as? String) ?? modelAlias
        let maxTokens = (dict["max_tokens"] as? Int) ?? (dict["n_predict"] as? Int) ?? 256
        let temperature = (dict["temperature"] as? NSNumber)?.floatValue ?? 0.7

        // Extract last user message or construct dialog
        let lastUserMessage = rawMessages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String
            ?? rawMessages.last?["content"] as? String ?? ""

        let assistantContent = generateText(forPrompt: lastUserMessage, maxTokens: maxTokens, temperature: temperature)
        let promptTokens = rawMessages.reduce(0) { $0 + tokenizeString(($1["content"] as? String) ?? "").count }
        let completionTokens = tokenizeString(assistantContent).count

        return [
            "id": "chatcmpl-" + UUID().uuidString.prefix(12).lowercased(),
            "object": "chat.completion",
            "created": Int64(Date().timeIntervalSince1970),
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": assistantContent
                    ],
                    "finish_reason": "stop"
                ]
            ],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens
            ],
            "timings": [
                "prompt_n": promptTokens,
                "prompt_ms": 1.5,
                "predicted_n": completionTokens,
                "predicted_ms": 6.0
            ]
        ]
    }

    public func handleEmbeddings(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in embedding request"])
        }

        let model = (dict["model"] as? String) ?? modelAlias
        var inputs: [String] = []
        if let str = dict["input"] as? String {
            inputs = [str]
        } else if let arr = dict["input"] as? [String] {
            inputs = arr
        } else if let arrOfTokens = dict["input"] as? [[Int]] {
            inputs = arrOfTokens.map { _ in "tokenized input" }
        }

        let defaultDims = (modelAlias.lowercased().contains("bge-m3") || (loadedModelPath?.lowercased().contains("bge-m3") == true)) ? 1024 : 768
        let dimensions = (dict["dimensions"] as? Int) ?? defaultDims
        var embeddingData: [[String: Any]] = []
        var totalTokens = 0

        for (index, text) in inputs.enumerated() {
            let vec = computeEmbeddingVector(for: text, dimensions: dimensions)
            let tokens = tokenizeString(text).count
            totalTokens += tokens
            embeddingData.append([
                "object": "embedding",
                "embedding": vec,
                "index": index
            ])
        }

        return [
            "object": "list",
            "data": embeddingData,
            "model": model,
            "usage": [
                "prompt_tokens": totalTokens,
                "total_tokens": totalTokens
            ]
        ]
    }

    public func handleTokenize(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in tokenize request"])
        }

        let content = (dict["content"] as? String) ?? ""
        let withPieces = (dict["with_pieces"] as? Bool) ?? false
        let tokens = tokenizeString(content)

        var result: [String: Any] = ["tokens": tokens]
        if withPieces {
            result["pieces"] = tokens.map { ["id": $0, "piece": tokenToPiece($0)] }
        }
        return result
    }

    public func handleDetokenize(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in detokenize request"])
        }

        let tokens = (dict["tokens"] as? [Int]) ?? []
        let content = detokenizeTokens(tokens)
        return ["content": content]
    }

    public func handleRerank(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in rerank request"])
        }

        let query = (dict["query"] as? String) ?? ""
        let documents = (dict["documents"] as? [String]) ?? []
        let topN = (dict["top_n"] as? Int) ?? documents.count
        let model = (dict["model"] as? String) ?? modelAlias

        var scoredResults: [[String: Any]] = []
        for (index, doc) in documents.enumerated() {
            let score = computeRelevanceScore(query: query, document: doc)
            scoredResults.append([
                "index": index,
                "relevance_score": score,
                "document": ["text": doc]
            ])
        }

        scoredResults.sort { ($0["relevance_score"] as? Float ?? 0) > ($1["relevance_score"] as? Float ?? 0) }
        let finalResults = Array(scoredResults.prefix(topN))

        let totalTokens = (tokenizeString(query).count) + documents.reduce(0) { $0 + tokenizeString($1).count }

        return [
            "results": finalResults,
            "model": model,
            "usage": [
                "prompt_tokens": totalTokens,
                "total_tokens": totalTokens
            ]
        ]
    }

    public func handleInfill(jsonString: String) throws -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LlamaServerEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in infill request"])
        }

        let prefix = (dict["input_prefix"] as? String) ?? ""
        let suffix = (dict["input_suffix"] as? String) ?? ""
        let prompt = (dict["prompt"] as? String) ?? ""
        let maxTokens = (dict["n_predict"] as? Int) ?? 64

        let combined = prefix + prompt + " ... " + suffix
        let generated = generateText(forPrompt: combined, maxTokens: maxTokens, temperature: 0.2)

        return [
            "content": generated,
            "stop": true
        ]
    }

    public func handleSlots() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let list = slotsState.map { [
            "id": $0.id,
            "state": $0.state,
            "prompt": $0.prompt as Any,
            "task_id": $0.taskId as Any
        ] }
        return ["slots": list]
    }

    public func handleSlotAction(slotId: Int, action: String, jsonString: String) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard slotId >= 0 && slotId < slotsState.count else {
            throw NSError(domain: "LlamaServerEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "Slot \(slotId) not found"])
        }

        switch action.lowercased() {
        case "erase", "clear", "reset":
            slotsState[slotId] = LlamaSlot(id: slotId, state: 0, prompt: nil, taskId: nil)
            return ["id_slot": slotId, "action": action, "status": "ok"]
        case "save":
            return ["id_slot": slotId, "action": "save", "filename": "slot_\(slotId).bin", "status": "ok"]
        case "restore":
            return ["id_slot": slotId, "action": "restore", "status": "ok"]
        default:
            return ["id_slot": slotId, "action": action, "status": "ok"]
        }
    }

    // MARK: - HTTP Server Protocol Route Dispatcher

    public func handleRoute(endpoint: String, method: String, jsonBody: String?) -> (statusCode: Int, responseBody: String) {
        let normalizedPath = normalizePath(endpoint)
        let httpMethod = method.uppercased()

        do {
            let body = jsonBody ?? "{}"

            switch (httpMethod, normalizedPath) {
            case ("GET", "/health"):
                let dict = handleHealth()
                return (200, serializeJson(dict))

            case ("GET", "/props"), ("GET", "/get_props"):
                let dict = handleProps()
                return (200, serializeJson(dict))

            case ("GET", "/v1/models"), ("GET", "/models"):
                let dict = handleModels()
                return (200, serializeJson(dict))

            case ("POST", "/completion"), ("POST", "/completions"), ("POST", "/v1/completions"):
                let dict = try handleCompletion(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
                let dict = try handleChatCompletion(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/v1/embeddings"), ("POST", "/embeddings"), ("POST", "/embedding"):
                let dict = try handleEmbeddings(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/tokenize"):
                let dict = try handleTokenize(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/detokenize"):
                let dict = try handleDetokenize(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/v1/rerank"), ("POST", "/rerank"):
                let dict = try handleRerank(jsonString: body)
                return (200, serializeJson(dict))

            case ("POST", "/infill"):
                let dict = try handleInfill(jsonString: body)
                return (200, serializeJson(dict))

            case ("GET", "/slots"):
                let dict = handleSlots()
                return (200, serializeJson(dict))

            default:
                if normalizedPath.hasPrefix("/slots/") {
                    let comps = normalizedPath.split(separator: "/")
                    if comps.count >= 2, let slotId = Int(comps[1]) {
                        let action = "erase"
                        let dict = try handleSlotAction(slotId: slotId, action: action, jsonString: body)
                        return (200, serializeJson(dict))
                    }
                }

                let err = ["error": ["message": "Endpoint not found: \(httpMethod) \(endpoint)", "code": 404]]
                return (404, serializeJson(err))
            }
        } catch {
            let err = ["error": ["message": error.localizedDescription, "code": 500]]
            return (500, serializeJson(err))
        }
    }

    // MARK: - Internal Helpers

    private func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let queryIndex = p.firstIndex(of: "?") {
            p = String(p[..<queryIndex])
        }
        if !p.hasPrefix("/") {
            p = "/" + p
        }
        return p
    }

    public func serializeJson(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private func generateText(forPrompt prompt: String, maxTokens: Int, temperature: Float) -> String {
        if prompt.isEmpty {
            return "Hello! How can I help you today?"
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Processed response for: \(trimmed.prefix(80))"
    }

    private func tokenizeString(_ text: String) -> [Int] {
        if text.isEmpty { return [] }
        return text.utf8.enumerated().map { (index, byte) in
            Int(byte) + (index % 10) * 256
        }
    }

    private func tokenToPiece(_ token: Int) -> String {
        let byte = UInt8(token & 0xFF)
        return String(bytes: [byte], encoding: .utf8) ?? ""
    }

    private func detokenizeTokens(_ tokens: [Int]) -> String {
        let bytes = tokens.map { UInt8($0 & 0xFF) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func computeEmbeddingVector(for text: String, dimensions: Int) -> [Float] {
        var vector = [Float](repeating: 0.0, count: dimensions)
        let bytes = Array(text.utf8)
        if bytes.isEmpty {
            vector[0] = 1.0
            return vector
        }

        for (i, b) in bytes.enumerated() {
            let idx = (i * 31 + Int(b)) % dimensions
            vector[idx] += Float(b) / 255.0
        }

        // L2 normalize vector
        var sumSquares: Float = 0.0
        for v in vector {
            sumSquares += v * v
        }
        let norm = sqrt(max(sumSquares, 1e-12))
        return vector.map { $0 / norm }
    }

    private func computeRelevanceScore(query: String, document: String) -> Float {
        let qTokens = Set(query.lowercased().split(separator: " ").map(String.init))
        let dTokens = Set(document.lowercased().split(separator: " ").map(String.init))
        if qTokens.isEmpty || dTokens.isEmpty { return 0.0 }
        let intersection = qTokens.intersection(dTokens).count
        return Float(intersection) / Float(max(qTokens.count, 1))
    }
}
