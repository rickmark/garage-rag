import Foundation
import OSLog
import LlamaCAPI
import LlamaClient

private let engineLogger = Logger(subsystem: "me.rickmark.garage-rag.llama-xpc", category: "llama.cpp")

/// `LlamaInferenceEngine` backed by llama.cpp, statically linked from //ext/llama_cpp.
///
/// One model and one context at a time, every request serialized under `lock`: the service is a
/// per-user helper, and llama.cpp contexts are not thread-safe. The request/response dictionaries
/// follow llama-server so the XPC front end, the loopback HTTP listener and the Python client all
/// see the same protocol.
///
/// Embeddings use the pooling the GGUF declares (BERT-style encoders carry CLS/mean, decoder
/// embedders such as Qwen3-Embedding use last-token); when a model declares none, tokens are
/// mean-pooled here. Vectors are L2-normalised, and `dimensions` truncates (Matryoshka) and
/// re-normalises. Completion and chat run a top-k / top-p / min-p / temperature sampler chain and
/// use the model's own chat template.
public final class LlamaCppEngine: LlamaInferenceEngine, @unchecked Sendable {
    // MARK: Configuration

    /// Options accepted in the `configJson` of `loadModel`, mirroring llama-server flags.
    private struct LoadOptions {
        var nCtx: UInt32 = 4096
        var nBatch: UInt32 = 2048
        var nGpuLayers: Int32 = -1
        var nThreads: Int32 = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        var pooling: llama_pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED

        init(json: String?) {
            guard let json = json, let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if let v = LoadOptions.int(dict["n_ctx"] ?? dict["context_size"]), v > 0 { nCtx = UInt32(v) }
            if let v = LoadOptions.int(dict["n_batch"]), v > 0 { nBatch = UInt32(v) }
            if let v = LoadOptions.int(dict["n_gpu_layers"] ?? dict["gpu_layers"]) { nGpuLayers = Int32(v) }
            if let v = LoadOptions.int(dict["threads"] ?? dict["n_threads"]), v > 0 { nThreads = Int32(v) }
            if let p = dict["pooling"] as? String {
                switch p.lowercased() {
                case "none": pooling = LLAMA_POOLING_TYPE_NONE
                case "mean": pooling = LLAMA_POOLING_TYPE_MEAN
                case "cls": pooling = LLAMA_POOLING_TYPE_CLS
                case "last": pooling = LLAMA_POOLING_TYPE_LAST
                case "rank": pooling = LLAMA_POOLING_TYPE_RANK
                default: break
                }
            }
        }

        private static func int(_ value: Any?) -> Int? {
            if let i = value as? Int { return i }
            if let n = value as? NSNumber { return n.intValue }
            if let s = value as? String { return Int(s) }
            return nil
        }
    }

    /// Everything that exists only while a model is loaded.
    private final class Loaded {
        let path: String
        let alias: String
        let model: OpaquePointer
        let vocab: OpaquePointer
        let context: OpaquePointer
        let options: LoadOptions
        let nEmbd: Int
        let nCtx: Int
        let nUbatch: Int
        let poolingOption: llama_pooling_type
        let nClsOut: Int
        let hasDecoder: Bool
        let hasEncoder: Bool
        let architecture: String
        let description: String
        let sizeBytes: UInt64
        let paramCount: UInt64

        init(path: String, alias: String, model: OpaquePointer, vocab: OpaquePointer, context: OpaquePointer,
             options: LoadOptions, nUbatch: Int, architecture: String, description: String) {
            self.path = path
            self.alias = alias
            self.model = model
            self.vocab = vocab
            self.context = context
            self.options = options
            self.nEmbd = Int(llama_model_n_embd(model))
            self.nCtx = Int(llama_n_ctx(context))
            self.nUbatch = nUbatch
            self.poolingOption = options.pooling
            self.nClsOut = Int(llama_model_n_cls_out(model))
            self.hasDecoder = llama_model_has_decoder(model)
            self.hasEncoder = llama_model_has_encoder(model)
            self.architecture = architecture
            self.description = description
            self.sizeBytes = llama_model_size(model)
            self.paramCount = llama_model_n_params(model)
        }

        deinit {
            llama_free(context)
            llama_model_free(model)
        }

        var supportsGeneration: Bool { hasDecoder }
        /// Rerankers carry a classification head (`n_cls_out > 0`); RANK pooling can also be forced.
        var supportsRerank: Bool { nClsOut > 0 || poolingOption == LLAMA_POOLING_TYPE_RANK }
    }

    private enum Phase {
        case idle
        case loading
        case ready
    }

    private let lock = NSLock()
    private var loaded: Loaded?
    private var phase: Phase = .idle
    private var busy = false
    private var lastError: String?

    /// URL of the loopback HTTP listener, reported in `/props` so clients can discover it.
    public var httpURL: String?

    private static let backendInit: Void = {
        llama_log_set({ level, text, _ in
            guard let text = text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            switch level {
            case GGML_LOG_LEVEL_ERROR:
                engineLogger.error("\(line, privacy: .public)")
            case GGML_LOG_LEVEL_WARN:
                engineLogger.warning("\(line, privacy: .public)")
            default:
                engineLogger.debug("\(line, privacy: .public)")
            }
        }, nil)
        llama_backend_init()
    }()

    public init() {
        _ = LlamaCppEngine.backendInit
    }

    deinit {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    // MARK: - LlamaInferenceEngine: model management

    public var currentModelPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return loaded?.path
    }

    public var lastLoadError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastError
    }

    public func loadModel(path: String, alias: String?, configJson: String?) -> (success: Bool, message: String) {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: path) else {
            lastError = "model file not found: \(path)"
            return (false, lastError!)
        }
        let options = LoadOptions(json: configJson)
        let resolvedAlias = (alias?.isEmpty == false ? alias! : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)

        loaded = nil
        phase = .loading

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = options.nGpuLayers
        guard let model = llama_model_load_from_file(path, mparams) else {
            phase = .idle
            lastError = "llama.cpp could not load \(path) (see the llama.cpp log for the reason)"
            return (false, lastError!)
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_model_free(model)
            phase = .idle
            lastError = "model has no vocabulary: \(path)"
            return (false, lastError!)
        }

        let hasDecoder = llama_model_has_decoder(model)
        let trainCtx = Int(llama_model_n_ctx_train(model))
        var nCtx = options.nCtx
        if trainCtx > 0 && nCtx > UInt32(trainCtx) {
            nCtx = UInt32(trainCtx)
        }
        // Encoder-only models (BERT family) must see a whole sequence in one physical batch, so
        // the ubatch is the full context there. Decoders take the llama-server default and get
        // their embedding inputs truncated to it (see handleEmbeddings).
        let nBatch = min(max(options.nBatch, 32), max(nCtx, 32))
        let nUbatch: UInt32 = hasDecoder ? min(nBatch, 512) : nBatch

        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        cparams.n_batch = nBatch
        cparams.n_ubatch = nUbatch
        cparams.n_seq_max = 1
        cparams.n_threads = options.nThreads
        cparams.n_threads_batch = options.nThreads
        cparams.embeddings = true
        cparams.pooling_type = options.pooling
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            phase = .idle
            lastError = "llama.cpp could not create a context for \(path) (n_ctx=\(nCtx))"
            return (false, lastError!)
        }

        let architecture = LlamaCppEngine.metaValue(model, key: "general.architecture") ?? "unknown"
        let description = LlamaCppEngine.modelDescription(model)
        loaded = Loaded(path: path, alias: resolvedAlias, model: model, vocab: vocab, context: context,
                        options: options, nUbatch: Int(nUbatch), architecture: architecture, description: description)
        phase = .ready
        lastError = nil

        let l = loaded!
        let summary = "\(resolvedAlias): \(description) [\(architecture)] n_ctx=\(l.nCtx) n_embd=\(l.nEmbd) "
            + "pooling=\(LlamaCppEngine.poolingName(l.poolingOption)) gpu_layers=\(options.nGpuLayers) threads=\(options.nThreads)"
        engineLogger.info("loaded \(summary, privacy: .public)")
        return (true, "Model loaded successfully from \(path) (\(summary))")
    }

    public func unloadModel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loaded = nil
        phase = .idle
        return true
    }

    // MARK: - LlamaInferenceEngine: status routes

    public func handleHealth() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let status: String
        switch phase {
        case .idle: status = "no_model_loaded"
        case .loading: status = "loading model"
        case .ready: status = "ok"
        }
        return [
            "status": status,
            "slots_idle": busy ? 0 : 1,
            "slots_processing": busy ? 1 : 0,
        ]
    }

    public func handleProps() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var props: [String: Any] = [
            "default_generation_settings": [
                "temperature": 0.8,
                "top_k": 40,
                "top_p": 0.95,
                "min_p": 0.05,
                "n_predict": -1,
            ],
            "total_slots": 1,
            "model_alias": loaded?.alias ?? "none",
            "model_path": loaded?.path as Any,
            "modal_capabilities": capabilities(),
            "engine": "llama.cpp",
        ]
        if let l = loaded {
            props["n_ctx"] = l.nCtx
            props["n_embd"] = l.nEmbd
            props["pooling"] = LlamaCppEngine.poolingName(l.poolingOption)
            props["n_cls_out"] = l.nClsOut
            props["architecture"] = l.architecture
            props["model_description"] = l.description
            props["model_size_bytes"] = l.sizeBytes
            props["model_params"] = l.paramCount
        }
        if let url = httpURL {
            props["http_url"] = url
        }
        return props
    }

    public func handleModels() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard let l = loaded else {
            return ["object": "list", "data": []]
        }
        let model: [String: Any] = [
            "id": l.alias,
            "object": "model",
            "created": Int64(Date().timeIntervalSince1970),
            "owned_by": "garage",
            "meta": [
                "path": l.path,
                "n_ctx": l.nCtx,
                "n_embd": l.nEmbd,
                "size": l.sizeBytes,
                "n_params": l.paramCount,
                "architecture": l.architecture,
            ],
        ]
        return ["object": "list", "data": [model]]
    }

    public func handleSlots() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["slots": [["id": 0, "state": busy ? 1 : 0, "prompt": NSNull(), "task_id": NSNull()]]]
    }

    public func handleSlotAction(slotId: Int, action: String, jsonString: String) throws -> [String: Any] {
        guard slotId == 0 else {
            throw LlamaEngineError(404, "Slot \(slotId) not found")
        }
        switch action.lowercased() {
        case "erase", "clear", "reset":
            lock.lock()
            if let l = loaded {
                llama_memory_clear(llama_get_memory(l.context), true)
            }
            lock.unlock()
            return ["id_slot": 0, "action": action, "status": "ok"]
        default:
            throw LlamaEngineError.unsupported("slot action '\(action)' is not supported")
        }
    }

    // MARK: - LlamaInferenceEngine: inference routes

    public func handleTokenize(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "tokenize")
        let content = (dict["content"] as? String) ?? ""
        let addSpecial = (dict["add_special"] as? Bool) ?? false
        let withPieces = (dict["with_pieces"] as? Bool) ?? false
        return try withLoaded { l in
            let tokens = try tokenize(l, content, addSpecial: addSpecial, parseSpecial: true)
            var result: [String: Any] = ["tokens": tokens.map { Int($0) }]
            if withPieces {
                result["pieces"] = tokens.map { ["id": Int($0), "piece": piece(l, $0, special: true)] }
            }
            return result
        }
    }

    public func handleDetokenize(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "detokenize")
        let tokens = ((dict["tokens"] as? [Int]) ?? []).map { llama_token($0) }
        return try withLoaded { l in
            ["content": detokenize(l, tokens)]
        }
    }

    public func handleEmbeddings(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "embeddings")
        var inputs: [String] = []
        if let str = dict["input"] as? String {
            inputs = [str]
        } else if let arr = dict["input"] as? [String] {
            inputs = arr
        } else if let arrOfTokens = dict["input"] as? [[Int]] {
            // Token-id inputs are decoded back to text so one code path tokenizes.
            inputs = try withLoaded { l in arrOfTokens.map { detokenize(l, $0.map { llama_token($0) }) } }
        } else {
            throw LlamaEngineError.badRequest("\"input\" must be a string or an array of strings")
        }
        let dimensions = dict["dimensions"] as? Int

        return try withLoaded { l in
            if let d = dimensions, d <= 0 || d > l.nEmbd {
                throw LlamaEngineError.badRequest("dimensions must be between 1 and \(l.nEmbd) for this model")
            }
            var data: [[String: Any]] = []
            var totalTokens = 0
            for (index, text) in inputs.enumerated() {
                let (vector, nTokens) = try embed(l, text)
                totalTokens += nTokens
                var out = vector
                if let d = dimensions, d < out.count {
                    out = LlamaCppEngine.normalized(Array(out.prefix(d)))
                }
                data.append(["object": "embedding", "embedding": out, "index": index])
            }
            return [
                "object": "list",
                "data": data,
                "model": l.alias,
                "usage": ["prompt_tokens": totalTokens, "total_tokens": totalTokens],
            ]
        }
    }

    public func handleCompletion(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "completion")
        let prompt = (dict["prompt"] as? String) ?? ""
        let params = GenerationParams(dict: dict, defaultMaxTokens: 128)
        return try withLoaded { l in
            let started = Date()
            let result = try generate(l, prompt: prompt, addSpecial: true, params: params)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            return [
                "content": result.text,
                "stop": true,
                "stop_type": result.finishReason == "stop" ? "eos" : "limit",
                "model": l.alias,
                "tokens_predicted": result.predictedTokens,
                "tokens_evaluated": result.promptTokens,
                "truncated": result.truncated,
                "generation_settings": params.asDictionary,
                "timings": [
                    "prompt_n": result.promptTokens,
                    "prompt_ms": result.promptMs,
                    "prompt_per_token_ms": result.promptTokens > 0 ? result.promptMs / Double(result.promptTokens) : 0,
                    "predicted_n": result.predictedTokens,
                    "predicted_ms": elapsedMs - result.promptMs,
                    "predicted_per_token_ms": result.predictedTokens > 0 ? (elapsedMs - result.promptMs) / Double(result.predictedTokens) : 0,
                ],
            ]
        }
    }

    public func handleChatCompletion(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "chat completion")
        guard let rawMessages = dict["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
            throw LlamaEngineError.badRequest("\"messages\" must be a non-empty array")
        }
        let messages: [(role: String, content: String)] = rawMessages.map {
            (($0["role"] as? String) ?? "user", ($0["content"] as? String) ?? "")
        }
        let params = GenerationParams(dict: dict, defaultMaxTokens: 256)
        return try withLoaded { l in
            let started = Date()
            let prompt = try applyChatTemplate(l, messages: messages)
            // The template already carries BOS where the model wants it.
            let result = try generate(l, prompt: prompt, addSpecial: false, params: params)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            return [
                "id": "chatcmpl-" + UUID().uuidString.prefix(12).lowercased(),
                "object": "chat.completion",
                "created": Int64(Date().timeIntervalSince1970),
                "model": l.alias,
                "choices": [
                    [
                        "index": 0,
                        "message": ["role": "assistant", "content": result.text],
                        "finish_reason": result.finishReason,
                    ],
                ],
                "usage": [
                    "prompt_tokens": result.promptTokens,
                    "completion_tokens": result.predictedTokens,
                    "total_tokens": result.promptTokens + result.predictedTokens,
                ],
                "timings": [
                    "prompt_n": result.promptTokens,
                    "prompt_ms": result.promptMs,
                    "predicted_n": result.predictedTokens,
                    "predicted_ms": elapsedMs - result.promptMs,
                ],
            ]
        }
    }

    public func handleRerank(jsonString: String) throws -> [String: Any] {
        let dict = try LlamaJSON.parseObject(jsonString, what: "rerank")
        guard let query = dict["query"] as? String else {
            throw LlamaEngineError.badRequest("\"query\" is required")
        }
        guard let documents = dict["documents"] as? [String] else {
            throw LlamaEngineError.badRequest("\"documents\" must be an array of strings")
        }
        let topN = (dict["top_n"] as? Int) ?? documents.count
        return try withLoaded { l in
            guard l.supportsRerank else {
                throw LlamaEngineError.unsupported("the loaded model is not a reranker (no classifier output; pass pooling=rank to force)")
            }
            var results: [[String: Any]] = []
            var totalTokens = 0
            for (index, document) in documents.enumerated() {
                let (score, nTokens) = try rerankScore(l, query: query, document: document)
                totalTokens += nTokens
                results.append(["index": index, "relevance_score": score, "document": ["text": document]])
            }
            results.sort { (($0["relevance_score"] as? Float) ?? 0) > (($1["relevance_score"] as? Float) ?? 0) }
            return [
                "model": l.alias,
                "object": "list",
                "results": Array(results.prefix(max(topN, 0))),
                "usage": ["prompt_tokens": totalTokens, "total_tokens": totalTokens],
            ]
        }
    }

    public func handleInfill(jsonString: String) throws -> [String: Any] {
        throw LlamaEngineError.unsupported("infill is not supported by this engine")
    }

    // MARK: - Locking helpers

    /// Runs `body` with the loaded model under the engine lock, marking the single slot busy.
    private func withLoaded<T>(_ body: (Loaded) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let l = loaded, phase == .ready else {
            throw LlamaEngineError.noModel()
        }
        busy = true
        defer { busy = false }
        return try body(l)
    }

    private func capabilities() -> [String] {
        var caps = ["embeddings", "tokenize", "detokenize"]
        if let l = loaded {
            if l.supportsGeneration {
                caps.append(contentsOf: ["completion", "chat"])
            }
            if l.supportsRerank {
                caps.append("rerank")
            }
        }
        return caps
    }

    // MARK: - Tokenization

    private func tokenize(_ l: Loaded, _ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
        let textLen = Int32(text.utf8.count)
        var capacity = Int32(text.utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        var n = text.withCString { cstr in
            llama_tokenize(l.vocab, cstr, textLen, &tokens, capacity, addSpecial, parseSpecial)
        }
        if n < 0 {
            capacity = -n
            tokens = [llama_token](repeating: 0, count: Int(capacity))
            n = text.withCString { cstr in
                llama_tokenize(l.vocab, cstr, textLen, &tokens, capacity, addSpecial, parseSpecial)
            }
        }
        guard n >= 0 else {
            throw LlamaEngineError(500, "tokenization failed (\(n))")
        }
        return Array(tokens.prefix(Int(n)))
    }

    private func piece(_ l: Loaded, _ token: llama_token, special: Bool) -> String {
        String(decoding: pieceBytes(l, token, special: special), as: UTF8.self)
    }

    private func pieceBytes(_ l: Loaded, _ token: llama_token, special: Bool) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 128)
        var n = llama_token_to_piece(l.vocab, token, &buf, Int32(buf.count), 0, special)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(l.vocab, token, &buf, Int32(buf.count), 0, special)
        }
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    private func detokenize(_ l: Loaded, _ tokens: [llama_token]) -> String {
        guard !tokens.isEmpty else { return "" }
        var buf = [CChar](repeating: 0, count: max(tokens.count * 8, 64))
        var n = llama_detokenize(l.vocab, tokens, Int32(tokens.count), &buf, Int32(buf.count), false, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_detokenize(l.vocab, tokens, Int32(tokens.count), &buf, Int32(buf.count), false, true)
        }
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Batches

    /// Feeds `tokens` at positions starting from `startPos` in chunks of `n_batch`, on sequence 0.
    /// `outputAll` marks every token as an output (needed for pooled embeddings); otherwise only
    /// the last token of the last chunk produces logits.
    private func feed(_ l: Loaded, tokens: [llama_token], startPos: Int, outputAll: Bool, encode: Bool) throws {
        let chunkSize = Int(llama_n_batch(l.context))
        var offset = 0
        while offset < tokens.count {
            let count = min(chunkSize, tokens.count - offset)
            var batch = llama_batch_init(Int32(count), 0, 1)
            defer { llama_batch_free(batch) }
            for i in 0..<count {
                batch.token[i] = tokens[offset + i]
                batch.pos[i] = llama_pos(startPos + offset + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                let isLastOverall = offset + i == tokens.count - 1
                batch.logits[i] = (outputAll || isLastOverall) ? 1 : 0
            }
            batch.n_tokens = Int32(count)
            let rc = encode ? llama_encode(l.context, batch) : llama_decode(l.context, batch)
            if rc != 0 {
                throw LlamaEngineError(500, "\(encode ? "llama_encode" : "llama_decode") failed with code \(rc) (n_tokens=\(count), n_ctx=\(l.nCtx))")
            }
            offset += count
        }
    }

    // MARK: - Embeddings

    private func embed(_ l: Loaded, _ text: String) throws -> (vector: [Float], tokens: Int) {
        var tokens = try tokenize(l, text, addSpecial: true, parseSpecial: true)
        if tokens.isEmpty {
            // An empty input still needs a token so the model yields a vector.
            tokens = try tokenize(l, " ", addSpecial: true, parseSpecial: true)
        }
        // Pooling happens inside one physical batch, so the input has to fit it.
        let limit = min(l.nCtx, l.nUbatch)
        if tokens.count > limit {
            engineLogger.warning("embedding input of \(tokens.count) tokens truncated to \(limit)")
            tokens = Array(tokens.prefix(limit))
        }

        llama_set_embeddings(l.context, true)
        llama_memory_clear(llama_get_memory(l.context), true)
        // Encoder-only models (no decoder) go through llama_encode; everything else decodes.
        let useEncode = l.hasEncoder && !l.hasDecoder
        try feed(l, tokens: tokens, startPos: 0, outputAll: true, encode: useEncode)

        let nEmbd = l.nEmbd
        var vector: [Float]
        // llama_get_embeddings_seq is NULL exactly when the context pools nothing (LLAMA_POOLING_TYPE_NONE).
        if let pooled = llama_get_embeddings_seq(l.context, 0) {
            vector = Array(UnsafeBufferPointer(start: pooled, count: nEmbd))
        } else {
            // No pooling declared by the model: mean over the token embeddings.
            vector = [Float](repeating: 0, count: nEmbd)
            var counted = 0
            for i in 0..<tokens.count {
                guard let row = llama_get_embeddings_ith(l.context, Int32(i)) else { continue }
                for j in 0..<nEmbd {
                    vector[j] += row[j]
                }
                counted += 1
            }
            if counted > 0 {
                let inv = 1 / Float(counted)
                for j in 0..<nEmbd {
                    vector[j] *= inv
                }
            }
        }
        guard vector.contains(where: { $0 != 0 && !$0.isNaN }) else {
            throw LlamaEngineError(500, "model produced an empty embedding")
        }
        return (LlamaCppEngine.normalized(vector), tokens.count)
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 1e-12 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Reranking

    /// Builds the reranker input llama.cpp expects: `[BOS] query [EOS] [SEP] document [EOS]`.
    private func rerankScore(_ l: Loaded, query: String, document: String) throws -> (Float, Int) {
        var tokens: [llama_token] = []
        let bos = llama_vocab_bos(l.vocab)
        let eos = llama_vocab_eos(l.vocab)
        let sep = llama_vocab_sep(l.vocab)
        if bos != LLAMA_TOKEN_NULL { tokens.append(bos) }
        tokens.append(contentsOf: try tokenize(l, query, addSpecial: false, parseSpecial: true))
        if eos != LLAMA_TOKEN_NULL { tokens.append(eos) }
        tokens.append(sep != LLAMA_TOKEN_NULL ? sep : eos)
        tokens.append(contentsOf: try tokenize(l, document, addSpecial: false, parseSpecial: true))
        if eos != LLAMA_TOKEN_NULL { tokens.append(eos) }

        let limit = min(l.nCtx, l.nUbatch)
        if tokens.count > limit {
            tokens = Array(tokens.prefix(limit))
        }
        llama_set_embeddings(l.context, true)
        llama_memory_clear(llama_get_memory(l.context), true)
        try feed(l, tokens: tokens, startPos: 0, outputAll: true, encode: l.hasEncoder && !l.hasDecoder)
        guard let out = llama_get_embeddings_seq(l.context, 0) else {
            throw LlamaEngineError(500, "reranker produced no score")
        }
        return (out[0], tokens.count)
    }

    // MARK: - Generation

    private struct GenerationParams {
        var maxTokens: Int
        var temperature: Float
        var topK: Int32
        var topP: Float
        var minP: Float
        var seed: UInt32
        var stop: [String]

        init(dict: [String: Any], defaultMaxTokens: Int) {
            let requested = (dict["n_predict"] as? Int) ?? (dict["max_tokens"] as? Int) ?? defaultMaxTokens
            maxTokens = requested < 0 ? Int.max : requested
            temperature = (dict["temperature"] as? NSNumber)?.floatValue ?? 0.8
            topK = Int32((dict["top_k"] as? Int) ?? 40)
            topP = (dict["top_p"] as? NSNumber)?.floatValue ?? 0.95
            minP = (dict["min_p"] as? NSNumber)?.floatValue ?? 0.05
            if let s = dict["seed"] as? Int, s >= 0 {
                seed = UInt32(truncatingIfNeeded: s)
            } else {
                seed = LLAMA_DEFAULT_SEED
            }
            if let list = dict["stop"] as? [String] {
                stop = list.filter { !$0.isEmpty }
            } else if let single = dict["stop"] as? String, !single.isEmpty {
                stop = [single]
            } else {
                stop = []
            }
        }

        var asDictionary: [String: Any] {
            [
                "temperature": temperature,
                "top_k": Int(topK),
                "top_p": topP,
                "min_p": minP,
                "n_predict": maxTokens == Int.max ? -1 : maxTokens,
                "seed": Int(seed),
                "stop": stop,
            ]
        }
    }

    private struct GenerationResult {
        var text: String
        var promptTokens: Int
        var predictedTokens: Int
        var finishReason: String
        var truncated: Bool
        var promptMs: Double
    }

    private func generate(_ l: Loaded, prompt: String, addSpecial: Bool, params: GenerationParams) throws -> GenerationResult {
        guard l.supportsGeneration else {
            throw LlamaEngineError.unsupported("the loaded model (\(l.architecture)) has no decoder and cannot generate text")
        }
        var promptTokens = try tokenize(l, prompt, addSpecial: addSpecial, parseSpecial: true)
        if promptTokens.isEmpty {
            let bos = llama_vocab_bos(l.vocab)
            if bos != LLAMA_TOKEN_NULL {
                promptTokens = [bos]
            }
        }
        // Keep room to answer: if the prompt fills the context, drop its oldest tokens.
        let reserve = min(max(params.maxTokens, 1), l.nCtx / 4)
        let promptLimit = max(l.nCtx - reserve, 1)
        var truncated = false
        if promptTokens.count > promptLimit {
            promptTokens = Array(promptTokens.suffix(promptLimit))
            truncated = true
        }

        llama_set_embeddings(l.context, false)
        llama_memory_clear(llama_get_memory(l.context), true)

        let promptStart = Date()
        try feed(l, tokens: promptTokens, startPos: 0, outputAll: false, encode: false)
        let promptMs = Date().timeIntervalSince(promptStart) * 1000

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LlamaEngineError(500, "could not create sampler")
        }
        defer { llama_sampler_free(sampler) }
        if params.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            if params.topK > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_k(params.topK))
            }
            if params.topP < 1 {
                llama_sampler_chain_add(sampler, llama_sampler_init_top_p(params.topP, 1))
            }
            if params.minP > 0 {
                llama_sampler_chain_add(sampler, llama_sampler_init_min_p(params.minP, 1))
            }
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(params.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(params.seed))
        }

        var output: [UInt8] = []
        var predicted = 0
        var finishReason = "length"
        var position = promptTokens.count
        let budget = min(params.maxTokens, max(l.nCtx - promptTokens.count, 0))

        while predicted < budget {
            let token = llama_sampler_sample(sampler, l.context, -1)
            llama_sampler_accept(sampler, token)
            if llama_vocab_is_eog(l.vocab, token) {
                finishReason = "stop"
                break
            }
            output.append(contentsOf: pieceBytes(l, token, special: false))
            predicted += 1

            if !params.stop.isEmpty {
                let tail = String(decoding: output.suffix(256), as: UTF8.self)
                if let hit = params.stop.first(where: { tail.contains($0) }) {
                    let full = String(decoding: output, as: UTF8.self)
                    if let range = full.range(of: hit, options: .backwards) {
                        output = Array(full[..<range.lowerBound].utf8)
                    }
                    finishReason = "stop"
                    break
                }
            }

            try feed(l, tokens: [token], startPos: position, outputAll: false, encode: false)
            position += 1
        }

        return GenerationResult(
            text: String(decoding: output, as: UTF8.self),
            promptTokens: promptTokens.count,
            predictedTokens: predicted,
            finishReason: finishReason,
            truncated: truncated,
            promptMs: promptMs
        )
    }

    /// Renders messages with the GGUF's chat template; falls back to a plain transcript when the
    /// model ships none.
    private func applyChatTemplate(_ l: Loaded, messages: [(role: String, content: String)]) throws -> String {
        guard let template = llama_model_chat_template(l.model, nil) else {
            var transcript = ""
            for m in messages {
                transcript += "\(m.role): \(m.content)\n"
            }
            transcript += "assistant:"
            return transcript
        }

        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        var chat: [llama_chat_message] = []
        for m in messages {
            let role = strdup(m.role)!
            let content = strdup(m.content)!
            cStrings.append(role)
            cStrings.append(content)
            chat.append(llama_chat_message(role: role, content: content))
        }

        var capacity = max(messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.utf8.count + 32 } * 2, 256)
        var buf = [CChar](repeating: 0, count: capacity)
        var n = llama_chat_apply_template(template, chat, chat.count, true, &buf, Int32(capacity))
        if n > Int32(capacity) {
            capacity = Int(n) + 1
            buf = [CChar](repeating: 0, count: capacity)
            n = llama_chat_apply_template(template, chat, chat.count, true, &buf, Int32(capacity))
        }
        guard n >= 0 else {
            throw LlamaEngineError(500, "the model's chat template could not be applied (\(n))")
        }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Metadata helpers

    private static func metaValue(_ model: OpaquePointer, key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_model_meta_val_str(model, key, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func modelDescription(_ model: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_model_desc(model, &buf, buf.count)
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func poolingName(_ pooling: llama_pooling_type) -> String {
        switch pooling {
        case LLAMA_POOLING_TYPE_NONE: return "none"
        case LLAMA_POOLING_TYPE_MEAN: return "mean"
        case LLAMA_POOLING_TYPE_CLS: return "cls"
        case LLAMA_POOLING_TYPE_LAST: return "last"
        case LLAMA_POOLING_TYPE_RANK: return "rank"
        default: return "unspecified"
        }
    }
}
