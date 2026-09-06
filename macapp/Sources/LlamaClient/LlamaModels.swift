import Foundation

// MARK: - Health & Props

public struct LlamaHealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let slotsIdle: Int?
    public let slotsProcessing: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case slotsIdle = "slots_idle"
        case slotsProcessing = "slots_processing"
    }

    public init(status: String = "ok", slotsIdle: Int? = 1, slotsProcessing: Int? = 0) {
        self.status = status
        self.slotsIdle = slotsIdle
        self.slotsProcessing = slotsProcessing
    }
}

public struct LlamaPropsResponse: Codable, Sendable, Equatable {
    public let defaultGenerationSettings: [String: AnyCodable]?
    public let totalSlots: Int?
    public let modelAlias: String?
    public let modalCapabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case defaultGenerationSettings = "default_generation_settings"
        case totalSlots = "total_slots"
        case modelAlias = "model_alias"
        case modalCapabilities = "modal_capabilities"
    }

    public init(
        defaultGenerationSettings: [String: AnyCodable]? = nil,
        totalSlots: Int? = 1,
        modelAlias: String? = "default",
        modalCapabilities: [String]? = ["completion", "chat", "embeddings", "tokenize", "rerank", "infill"]
    ) {
        self.defaultGenerationSettings = defaultGenerationSettings
        self.totalSlots = totalSlots
        self.modelAlias = modelAlias
        self.modalCapabilities = modalCapabilities
    }
}

// MARK: - Models

public struct LlamaModel: Codable, Sendable, Equatable {
    public let id: String
    public let object: String
    public let created: Int64
    public let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }

    public init(
        id: String,
        object: String = "model",
        created: Int64 = Int64(Date().timeIntervalSince1970),
        ownedBy: String = "llamacpp"
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
    }
}

public struct LlamaModelsResponse: Codable, Sendable, Equatable {
    public let object: String
    public let data: [LlamaModel]

    public init(object: String = "list", data: [LlamaModel]) {
        self.object = object
        self.data = data
    }
}

// MARK: - Usage & Timings

public struct LlamaUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int?
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    public init(promptTokens: Int = 0, completionTokens: Int? = 0, totalTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct LlamaTimings: Codable, Sendable, Equatable {
    public let promptN: Int?
    public let promptMs: Double?
    public let promptPerTokenMs: Double?
    public let predictedN: Int?
    public let predictedMs: Double?
    public let predictedPerTokenMs: Double?

    enum CodingKeys: String, CodingKey {
        case promptN = "prompt_n"
        case promptMs = "prompt_ms"
        case promptPerTokenMs = "prompt_per_token_ms"
        case predictedN = "predicted_n"
        case predictedMs = "predicted_ms"
        case predictedPerTokenMs = "predicted_per_token_ms"
    }

    public init(
        promptN: Int? = nil,
        promptMs: Double? = nil,
        promptPerTokenMs: Double? = nil,
        predictedN: Int? = nil,
        predictedMs: Double? = nil,
        predictedPerTokenMs: Double? = nil
    ) {
        self.promptN = promptN
        self.promptMs = promptMs
        self.promptPerTokenMs = promptPerTokenMs
        self.predictedN = predictedN
        self.predictedMs = predictedMs
        self.predictedPerTokenMs = predictedPerTokenMs
    }
}

// MARK: - Completion

public struct LlamaCompletionRequest: Codable, Sendable, Equatable {
    public var prompt: String
    public var model: String?
    public var temperature: Float?
    public var topK: Int?
    public var topP: Float?
    public var minP: Float?
    public var nPredict: Int?
    public var maxTokens: Int?
    public var stream: Bool?
    public var stop: [String]?
    public var presencePenalty: Float?
    public var frequencyPenalty: Float?
    public var seed: Int?

    enum CodingKeys: String, CodingKey {
        case prompt
        case model
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case minP = "min_p"
        case nPredict = "n_predict"
        case maxTokens = "max_tokens"
        case stream
        case stop
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case seed
    }

    public init(
        prompt: String,
        model: String? = nil,
        temperature: Float? = nil,
        topK: Int? = nil,
        topP: Float? = nil,
        minP: Float? = nil,
        nPredict: Int? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil,
        stop: [String]? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        seed: Int? = nil
    ) {
        self.prompt = prompt
        self.model = model
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.nPredict = nPredict
        self.maxTokens = maxTokens
        self.stream = stream
        self.stop = stop
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
    }
}

public struct LlamaCompletionResponse: Codable, Sendable, Equatable {
    public let content: String
    public let stop: Bool?
    public let model: String?
    public let tokensPredicted: Int?
    public let tokensEvaluated: Int?
    public let generationSettings: [String: AnyCodable]?
    public let timings: LlamaTimings?

    enum CodingKeys: String, CodingKey {
        case content
        case stop
        case model
        case tokensPredicted = "tokens_predicted"
        case tokensEvaluated = "tokens_evaluated"
        case generationSettings = "generation_settings"
        case timings
    }

    public init(
        content: String,
        stop: Bool? = true,
        model: String? = nil,
        tokensPredicted: Int? = nil,
        tokensEvaluated: Int? = nil,
        generationSettings: [String: AnyCodable]? = nil,
        timings: LlamaTimings? = nil
    ) {
        self.content = content
        self.stop = stop
        self.model = model
        self.tokensPredicted = tokensPredicted
        self.tokensEvaluated = tokensEvaluated
        self.generationSettings = generationSettings
        self.timings = timings
    }
}

// MARK: - Chat Completion

public struct LlamaChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String
    public let name: String?

    public init(role: String, content: String, name: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
    }
}

public struct LlamaChatCompletionRequest: Codable, Sendable, Equatable {
    public var messages: [LlamaChatMessage]
    public var model: String?
    public var temperature: Float?
    public var topK: Int?
    public var topP: Float?
    public var minP: Float?
    public var maxTokens: Int?
    public var stream: Bool?
    public var stop: [String]?
    public var presencePenalty: Float?
    public var frequencyPenalty: Float?
    public var seed: Int?

    enum CodingKeys: String, CodingKey {
        case messages
        case model
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case minP = "min_p"
        case maxTokens = "max_tokens"
        case stream
        case stop
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case seed
    }

    public init(
        messages: [LlamaChatMessage],
        model: String? = nil,
        temperature: Float? = nil,
        topK: Int? = nil,
        topP: Float? = nil,
        minP: Float? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil,
        stop: [String]? = nil,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        seed: Int? = nil
    ) {
        self.messages = messages
        self.model = model
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.maxTokens = maxTokens
        self.stream = stream
        self.stop = stop
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.seed = seed
    }
}

public struct LlamaChatChoice: Codable, Sendable, Equatable {
    public let index: Int
    public let message: LlamaChatMessage
    public let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }

    public init(index: Int = 0, message: LlamaChatMessage, finishReason: String? = "stop") {
        self.index = index
        self.message = message
        self.finishReason = finishReason
    }
}

public struct LlamaChatCompletionResponse: Codable, Sendable, Equatable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: [LlamaChatChoice]
    public let usage: LlamaUsage?
    public let timings: LlamaTimings?

    public init(
        id: String = "chatcmpl-" + UUID().uuidString,
        object: String = "chat.completion",
        created: Int64 = Int64(Date().timeIntervalSince1970),
        model: String = "default",
        choices: [LlamaChatChoice],
        usage: LlamaUsage? = nil,
        timings: LlamaTimings? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.timings = timings
    }
}

// MARK: - Embeddings

public struct LlamaEmbeddingRequest: Codable, Sendable, Equatable {
    public var input: [String]
    public var model: String?
    public var encodingFormat: String?
    public var dimensions: Int?

    enum CodingKeys: String, CodingKey {
        case input
        case model
        case encodingFormat = "encoding_format"
        case dimensions
    }

    public init(
        input: [String],
        model: String? = nil,
        encodingFormat: String? = "float",
        dimensions: Int? = nil
    ) {
        self.input = input
        self.model = model
        self.encodingFormat = encodingFormat
        self.dimensions = dimensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.encodingFormat = try container.decodeIfPresent(String.self, forKey: .encodingFormat)
        self.dimensions = try container.decodeIfPresent(Int.self, forKey: .dimensions)

        if let stringInput = try? container.decode(String.self, forKey: .input) {
            self.input = [stringInput]
        } else if let arrayInput = try? container.decode([String].self, forKey: .input) {
            self.input = arrayInput
        } else {
            self.input = []
        }
    }
}

public struct LlamaEmbeddingData: Codable, Sendable, Equatable {
    public let object: String
    public let embedding: [Float]
    public let index: Int

    public init(object: String = "embedding", embedding: [Float], index: Int = 0) {
        self.object = object
        self.embedding = embedding
        self.index = index
    }
}

public struct LlamaEmbeddingResponse: Codable, Sendable, Equatable {
    public let object: String
    public let data: [LlamaEmbeddingData]
    public let model: String
    public let usage: LlamaUsage

    public init(
        object: String = "list",
        data: [LlamaEmbeddingData],
        model: String = "default",
        usage: LlamaUsage = LlamaUsage()
    ) {
        self.object = object
        self.data = data
        self.model = model
        self.usage = usage
    }
}

// MARK: - Tokenize & Detokenize

public struct LlamaTokenizeRequest: Codable, Sendable, Equatable {
    public var content: String
    public var addSpecial: Bool?
    public var withPieces: Bool?

    enum CodingKeys: String, CodingKey {
        case content
        case addSpecial = "add_special"
        case withPieces = "with_pieces"
    }

    public init(content: String, addSpecial: Bool? = true, withPieces: Bool? = false) {
        self.content = content
        self.addSpecial = addSpecial
        self.withPieces = withPieces
    }
}

public struct LlamaTokenPiece: Codable, Sendable, Equatable {
    public let id: Int
    public let piece: String

    public init(id: Int, piece: String) {
        self.id = id
        self.piece = piece
    }
}

public struct LlamaTokenizeResponse: Codable, Sendable, Equatable {
    public let tokens: [Int]
    public let pieces: [LlamaTokenPiece]?

    public init(tokens: [Int], pieces: [LlamaTokenPiece]? = nil) {
        self.tokens = tokens
        self.pieces = pieces
    }
}

public struct LlamaDetokenizeRequest: Codable, Sendable, Equatable {
    public var tokens: [Int]

    public init(tokens: [Int]) {
        self.tokens = tokens
    }
}

public struct LlamaDetokenizeResponse: Codable, Sendable, Equatable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

// MARK: - Rerank

public struct LlamaRerankRequest: Codable, Sendable, Equatable {
    public var query: String
    public var documents: [String]
    public var topN: Int?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case query
        case documents
        case topN = "top_n"
        case model
    }

    public init(query: String, documents: [String], topN: Int? = nil, model: String? = nil) {
        self.query = query
        self.documents = documents
        self.topN = topN
        self.model = model
    }
}

public struct LlamaRerankResult: Codable, Sendable, Equatable {
    public let index: Int
    public let relevanceScore: Float
    public let document: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case relevanceScore = "relevance_score"
        case document
    }

    public init(index: Int, relevanceScore: Float, document: [String: String]? = nil) {
        self.index = index
        self.relevanceScore = relevanceScore
        self.document = document
    }
}

public struct LlamaRerankResponse: Codable, Sendable, Equatable {
    public let results: [LlamaRerankResult]
    public let model: String?
    public let usage: LlamaUsage?

    public init(results: [LlamaRerankResult], model: String? = nil, usage: LlamaUsage? = nil) {
        self.results = results
        self.model = model
        self.usage = usage
    }
}

// MARK: - Infill

public struct LlamaInfillRequest: Codable, Sendable, Equatable {
    public var inputPrefix: String
    public var inputSuffix: String
    public var prompt: String?
    public var nPredict: Int?
    public var temperature: Float?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case inputPrefix = "input_prefix"
        case inputSuffix = "input_suffix"
        case prompt
        case nPredict = "n_predict"
        case temperature
        case stream
    }

    public init(
        inputPrefix: String,
        inputSuffix: String,
        prompt: String? = nil,
        nPredict: Int? = nil,
        temperature: Float? = nil,
        stream: Bool? = nil
    ) {
        self.inputPrefix = inputPrefix
        self.inputSuffix = inputSuffix
        self.prompt = prompt
        self.nPredict = nPredict
        self.temperature = temperature
        self.stream = stream
    }
}

public struct LlamaInfillResponse: Codable, Sendable, Equatable {
    public let content: String
    public let stop: Bool?

    public init(content: String, stop: Bool? = true) {
        self.content = content
        self.stop = stop
    }
}

// MARK: - Slots

public struct LlamaSlot: Codable, Sendable, Equatable {
    public let id: Int
    public let state: Int
    public let prompt: String?
    public let taskId: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case prompt
        case taskId = "task_id"
    }

    public init(id: Int, state: Int = 0, prompt: String? = nil, taskId: Int? = nil) {
        self.id = id
        self.state = state
        self.prompt = prompt
        self.taskId = taskId
    }
}

public struct LlamaSlotsResponse: Codable, Sendable, Equatable {
    public let slots: [LlamaSlot]

    public init(slots: [LlamaSlot]) {
        self.slots = slots
    }
}

// MARK: - AnyCodable Helper for arbitrary JSON values

public struct AnyCodable: Codable, @unchecked Sendable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported AnyCodable value: \(value)")
            throw EncodingError.invalidValue(value, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
