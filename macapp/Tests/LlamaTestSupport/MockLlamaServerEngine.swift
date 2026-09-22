import Foundation
import LlamaClient

/// Test double for `LlamaInferenceEngine`.
///
/// It answers every llama-server route with deterministic, obviously synthetic data: completions
/// echo the prompt behind a fixed prefix, embeddings are a normalised byte histogram, tokens are
/// bytes. That is enough for `LlamaClient` and `LlamaService` tests to exercise request plumbing,
/// state transitions and JSON shapes without a helper process or a GGUF file. It lives in a
/// testonly module so nothing shipped can be built against it.
public final class MockLlamaServerEngine: LlamaInferenceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var loadedModelPath: String?
    private var modelAlias: String
    private var isModelLoaded: Bool
    private let totalSlots: Int
    private var slotsState: [LlamaSlot]

    public var currentModelPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return loadedModelPath
    }

    public init(modelPath: String? = nil, modelAlias: String = "default", totalSlots: Int = 1) {
        self.loadedModelPath = modelPath
        self.modelAlias = modelAlias
        self.isModelLoaded = true
        self.totalSlots = max(1, totalSlots)
        self.slotsState = (0..<self.totalSlots).map { LlamaSlot(id: $0, state: 0, prompt: nil, taskId: nil) }
    }

    // MARK: - Model management

    public func loadModel(path: String, alias: String?, configJson: String?) -> (success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }
        loadedModelPath = path
        if let alias = alias, !alias.isEmpty {
            modelAlias = alias
        }
        isModelLoaded = true
        return (true, "Model loaded successfully from \(path)")
    }

    public func unloadModel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadedModelPath = nil
        isModelLoaded = false
        return true
    }

    // MARK: - Routes

    public func handleHealth() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let idle = slotsState.filter { $0.state == 0 }.count
        return [
            "status": isModelLoaded ? "ok" : "no_model_loaded",
            "slots_idle": idle,
            "slots_processing": slotsState.count - idle,
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
                "n_predict": -1,
            ],
            "total_slots": totalSlots,
            "model_alias": modelAlias,
            "model_path": loadedModelPath as Any,
            "modal_capabilities": ["completion", "chat", "embeddings", "tokenize", "detokenize", "rerank", "infill"],
        ]
    }

    public func handleModels() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let model: [String: Any] = [
            "id": modelAlias,
            "object": "model",
            "created": Int64(Date().timeIntervalSince1970),
            "owned_by": "mock",
        ]
        return ["object": "list", "data": [model]]
    }

    public func handleCompletion(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "completion")
        let prompt = (dict["prompt"] as? String) ?? ""
        let model = (dict["model"] as? String) ?? modelAlias
        let maxTokens = (dict["n_predict"] as? Int) ?? (dict["max_tokens"] as? Int) ?? 128
        let temperature = (dict["temperature"] as? NSNumber)?.floatValue ?? 0.7
        let generated = generateText(forPrompt: prompt)
        let promptTokens = tokenizeString(prompt).count
        let predictedTokens = tokenizeString(generated).count
        return [
            "content": generated,
            "stop": true,
            "model": model,
            "tokens_predicted": predictedTokens,
            "tokens_evaluated": promptTokens,
            "generation_settings": ["temperature": temperature, "max_tokens": maxTokens],
            "timings": [
                "prompt_n": promptTokens,
                "prompt_ms": 1.2,
                "prompt_per_token_ms": 0.2,
                "predicted_n": predictedTokens,
                "predicted_ms": 5.4,
                "predicted_per_token_ms": 0.5,
            ],
        ]
    }

    public func handleChatCompletion(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "chat completion")
        let rawMessages = (dict["messages"] as? [[String: Any]]) ?? []
        let model = (dict["model"] as? String) ?? modelAlias
        let lastUserMessage = rawMessages.reversed().first { ($0["role"] as? String) == "user" }?["content"] as? String
        let assistantContent = generateText(forPrompt: lastUserMessage ?? "")
        let promptTokens = rawMessages.reduce(0) { $0 + tokenizeString(($1["content"] as? String) ?? "").count }
        let completionTokens = tokenizeString(assistantContent).count
        return [
            "id": "chatcmpl-" + UUID().uuidString.prefix(12).lowercased(),
            "object": "chat.completion",
            "created": Int64(Date().timeIntervalSince1970),
            "model": model,
            "choices": [
                ["index": 0, "message": ["role": "assistant", "content": assistantContent], "finish_reason": "stop"],
            ],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
            "timings": ["prompt_n": promptTokens, "prompt_ms": 1.5, "predicted_n": completionTokens, "predicted_ms": 6.0],
        ]
    }

    public func handleEmbeddings(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "embeddings")
        let model = (dict["model"] as? String) ?? modelAlias
        var inputs: [String] = []
        if let str = dict["input"] as? String {
            inputs = [str]
        } else if let arr = dict["input"] as? [String] {
            inputs = arr
        } else if let arrOfTokens = dict["input"] as? [[Int]] {
            inputs = arrOfTokens.map { detokenizeTokens($0) }
        }
        let defaultDims = modelAlias.lowercased().contains("bge-m3") || (loadedModelPath?.lowercased().contains("bge-m3") == true) ? 1024 : 768
        let dimensions = (dict["dimensions"] as? Int) ?? defaultDims
        var embeddingData: [[String: Any]] = []
        var totalTokens = 0
        for (index, text) in inputs.enumerated() {
            embeddingData.append(["object": "embedding", "embedding": computeEmbeddingVector(for: text, dimensions: dimensions), "index": index])
            totalTokens += tokenizeString(text).count
        }
        return [
            "object": "list",
            "data": embeddingData,
            "model": model,
            "usage": ["prompt_tokens": totalTokens, "total_tokens": totalTokens],
        ]
    }

    public func handleTokenize(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "tokenize")
        let content = (dict["content"] as? String) ?? ""
        let tokens = tokenizeString(content)
        var result: [String: Any] = ["tokens": tokens]
        if (dict["with_pieces"] as? Bool) ?? false {
            result["pieces"] = tokens.map { ["id": $0, "piece": tokenToPiece($0)] }
        }
        return result
    }

    public func handleDetokenize(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "detokenize")
        return ["content": detokenizeTokens((dict["tokens"] as? [Int]) ?? [])]
    }

    public func handleRerank(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "rerank")
        let query = (dict["query"] as? String) ?? ""
        let documents = (dict["documents"] as? [String]) ?? []
        let topN = (dict["top_n"] as? Int) ?? documents.count
        let model = (dict["model"] as? String) ?? modelAlias
        let qTokens = Set(query.lowercased().split(separator: " ").map(String.init))
        var scored: [[String: Any]] = []
        for (index, doc) in documents.enumerated() {
            let dTokens = Set(doc.lowercased().split(separator: " ").map(String.init))
            let score: Float = qTokens.isEmpty || dTokens.isEmpty ? 0 : Float(qTokens.intersection(dTokens).count) / Float(max(qTokens.count, 1))
            scored.append(["index": index, "relevance_score": score, "document": ["text": doc]])
        }
        scored.sort { (($0["relevance_score"] as? Float) ?? 0) > (($1["relevance_score"] as? Float) ?? 0) }
        let totalTokens = tokenizeString(query).count + documents.reduce(0) { $0 + tokenizeString($1).count }
        return [
            "results": Array(scored.prefix(topN)),
            "model": model,
            "usage": ["prompt_tokens": totalTokens, "total_tokens": totalTokens],
        ]
    }

    public func handleInfill(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "infill")
        let prefix = (dict["input_prefix"] as? String) ?? ""
        let suffix = (dict["input_suffix"] as? String) ?? ""
        let prompt = (dict["prompt"] as? String) ?? ""
        return ["content": generateText(forPrompt: prefix + prompt + " ... " + suffix), "stop": true]
    }

    public func handleSlots() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["slots": slotsState.map { ["id": $0.id, "state": $0.state, "prompt": $0.prompt as Any, "task_id": $0.taskId as Any] }]
    }

    public func handleSlotAction(slotId: Int, action: String, jsonString: String) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard slotId >= 0 && slotId < slotsState.count else {
            throw LlamaEngineError(404, "Slot \(slotId) not found")
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

    // MARK: - Synthetic data

    private func generateText(forPrompt prompt: String) -> String {
        if prompt.isEmpty {
            return "Hello! How can I help you today?"
        }
        return "Processed response for: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
    }

    private func tokenizeString(_ text: String) -> [Int] {
        text.utf8.enumerated().map { index, byte in Int(byte) + (index % 10) * 256 }
    }

    private func tokenToPiece(_ token: Int) -> String {
        String(bytes: [UInt8(token & 0xFF)], encoding: .utf8) ?? ""
    }

    private func detokenizeTokens(_ tokens: [Int]) -> String {
        String(bytes: tokens.map { UInt8($0 & 0xFF) }, encoding: .utf8) ?? ""
    }

    private func computeEmbeddingVector(for text: String, dimensions: Int) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let bytes = Array(text.utf8)
        if bytes.isEmpty {
            vector[0] = 1
            return vector
        }
        for (i, b) in bytes.enumerated() {
            vector[(i * 31 + Int(b)) % dimensions] += Float(b) / 255
        }
        let norm = sqrt(max(vector.reduce(0) { $0 + $1 * $1 }, 1e-12))
        return vector.map { $0 / norm }
    }
}
