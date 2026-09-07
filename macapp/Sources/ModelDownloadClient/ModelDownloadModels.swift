import Foundation

/// Represents the current status of a download task.
public enum DownloadStatus: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

/// Request to initiate downloading a model file.
public struct ModelDownloadRequest: Codable, Sendable {
    /// Remote URL of the model to download (or Hugging Face resolve URL).
    public var url: String
    /// Optional target filename (if nil, extracted from URL).
    public var filename: String?
    /// Optional logical model identifier / alias.
    public var modelId: String?
    /// Optional destination directory path.
    public var destinationDirectory: String?
    /// Optional expected size in bytes.
    public var expectedSize: Int64?
    /// Optional expected SHA256 checksum for verification.
    public var sha256: String?
    /// Optional Authorization header token (e.g. HuggingFace token).
    public var authToken: String?

    public init(
        url: String,
        filename: String? = nil,
        modelId: String? = nil,
        destinationDirectory: String? = nil,
        expectedSize: Int64? = nil,
        sha256: String? = nil,
        authToken: String? = nil
    ) {
        self.url = url
        self.filename = filename
        self.modelId = modelId
        self.destinationDirectory = destinationDirectory
        self.expectedSize = expectedSize
        self.sha256 = sha256
        self.authToken = authToken
    }
}

/// Information and progress of an individual download task.
public struct DownloadTaskInfo: Codable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var filename: String
    public var destinationPath: String
    public var status: DownloadStatus
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var fractionCompleted: Double
    public var bytesPerSecond: Double
    public var estimatedTimeRemaining: TimeInterval?
    public var errorMessage: String?
    public var modelId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        url: String,
        filename: String,
        destinationPath: String,
        status: DownloadStatus = .queued,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        fractionCompleted: Double = 0.0,
        bytesPerSecond: Double = 0.0,
        estimatedTimeRemaining: TimeInterval? = nil,
        errorMessage: String? = nil,
        modelId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.destinationPath = destinationPath
        self.status = status
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.fractionCompleted = fractionCompleted
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
        self.errorMessage = errorMessage
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var formattedProgress: String {
        let downloadedStr = ByteCountFormatter.string(fromByteCount: bytesDownloaded, countStyle: .file)
        if totalBytes > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let percent = Int(fractionCompleted * 100)
            return "\(downloadedStr) / \(totalStr) (\(percent)%)"
        } else {
            return downloadedStr
        }
    }

    public var formattedSpeed: String {
        guard status == .downloading, bytesPerSecond > 0 else { return "" }
        let speedStr = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(speedStr)/s"
    }

    public var formattedETA: String {
        guard status == .downloading, let eta = estimatedTimeRemaining, eta > 0, eta < 86400 else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: eta) ?? ""
    }
}

/// Metadata describing a model already downloaded and stored locally.
public struct DownloadedModelInfo: Codable, Identifiable, Sendable {
    public var id: String { path }
    public var name: String
    public var filename: String
    public var path: String
    public var size: Int64
    public var formattedSize: String
    public var modifiedAt: Date
    public var format: String

    public init(
        name: String,
        filename: String,
        path: String,
        size: Int64,
        modifiedAt: Date = Date(),
        format: String = "gguf"
    ) {
        self.name = name
        self.filename = filename
        self.path = path
        self.size = size
        self.formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        self.modifiedAt = modifiedAt
        self.format = format
    }
}

/// Model category in the preset catalog.
public enum ModelCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case general = "General LLM"
    case coder = "Code & Developer"
    case reasoning = "Reasoning"
    case embedding = "Embedding"

    public var id: String { rawValue }
}

/// Item in the curated model download catalog.
public struct ModelCatalogItem: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var category: ModelCategory
    public var downloadUrl: String
    public var filename: String
    public var sizeBytes: Int64
    public var formattedSize: String
    public var parameterSize: String
    public var quantization: String
    public var contextLength: Int
    public var defaultGpuLayers: Int

    public init(
        id: String,
        name: String,
        description: String,
        category: ModelCategory,
        downloadUrl: String,
        filename: String,
        sizeBytes: Int64,
        parameterSize: String,
        quantization: String,
        contextLength: Int = 4096,
        defaultGpuLayers: Int = 33
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.downloadUrl = downloadUrl
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.formattedSize = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.contextLength = contextLength
        self.defaultGpuLayers = defaultGpuLayers
    }
}

/// Curated catalog of tested and compatible GGUF models from Hugging Face.
public struct ModelPresetCatalog {
    public static let items: [ModelCatalogItem] = [
        ModelCatalogItem(
            id: "llama-3.2-1b-instruct",
            name: "Llama 3.2 1B Instruct",
            description: "Ultra-fast and lightweight instruction-tuned model by Meta, ideal for quick queries and low memory.",
            category: .general,
            downloadUrl: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            sizeBytes: 808_000_000,
            parameterSize: "1.23B",
            quantization: "Q4_K_M",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "llama-3.2-3b-instruct",
            name: "Llama 3.2 3B Instruct",
            description: "Balanced compact model by Meta offering strong reasoning and conversational quality.",
            category: .general,
            downloadUrl: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            filename: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            sizeBytes: 2_020_000_000,
            parameterSize: "3.21B",
            quantization: "Q4_K_M",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "qwen-2.5-coder-7b",
            name: "Qwen 2.5 Coder 7B",
            description: "State-of-the-art open-source code generation, debugging, and software reasoning model by Alibaba.",
            category: .coder,
            downloadUrl: "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            filename: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            sizeBytes: 4_680_000_000,
            parameterSize: "7.61B",
            quantization: "Q4_K_M",
            contextLength: 16384,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "mistral-7b-instruct-v0.3",
            name: "Mistral 7B Instruct v0.3",
            description: "Highly capable and widely used 7B instruction model with strong reasoning by Mistral AI.",
            category: .general,
            downloadUrl: "https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            filename: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            sizeBytes: 4_370_000_000,
            parameterSize: "7.25B",
            quantization: "Q4_K_M",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "deepseek-r1-distill-qwen-7b",
            name: "DeepSeek R1 Distill Qwen 7B",
            description: "Reasoning and chain-of-thought model distilled from DeepSeek R1 into Qwen 2.5 7B architecture.",
            category: .reasoning,
            downloadUrl: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
            filename: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
            sizeBytes: 4_680_000_000,
            parameterSize: "7.61B",
            quantization: "Q4_K_M",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "bge-m3-gguf",
            name: "BGE-M3 Embeddings (GGUF)",
            description: "Multi-lingual, multi-functionality (dense, sparse, multi-vector) high quality embedding model.",
            category: .embedding,
            downloadUrl: "https://huggingface.co/CompendiumLabs/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf",
            filename: "bge-m3-Q8_0.gguf",
            sizeBytes: 605_000_000,
            parameterSize: "567M",
            quantization: "Q8_0",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "nomic-embed-text-v1.5",
            name: "Nomic Embed Text v1.5 (GGUF)",
            description: "Compact 137M parameter embedding model with 8192 context window and high retrieval accuracy.",
            category: .embedding,
            downloadUrl: "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf",
            filename: "nomic-embed-text-v1.5.Q8_0.gguf",
            sizeBytes: 152_000_000,
            parameterSize: "137M",
            quantization: "Q8_0",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
        ModelCatalogItem(
            id: "snowflake-arctic-embed-m",
            name: "Snowflake Arctic Embed M (GGUF)",
            description: "Optimized retrieval embedding model tuned for high performance search pipelines.",
            category: .embedding,
            downloadUrl: "https://huggingface.co/ChristianAzinn/snowflake-arctic-embed-m-gguf/resolve/main/snowflake-arctic-embed-m.Q8_0.gguf",
            filename: "snowflake-arctic-embed-m.Q8_0.gguf",
            sizeBytes: 120_000_000,
            parameterSize: "110M",
            quantization: "Q8_0",
            contextLength: 8192,
            defaultGpuLayers: 33
        ),
    ]

    public static func item(for id: String) -> ModelCatalogItem? {
        items.first { $0.id == id }
    }

    public static func item(forModelIdOrSlug idOrSlug: String) -> ModelCatalogItem? {
        if let exact = items.first(where: { $0.id == idOrSlug || $0.filename.lowercased() == idOrSlug.lowercased() }) {
            return exact
        }
        let normalized = idOrSlug.lowercased()
        if normalized.contains("bge-m3") || normalized.contains("baai/bge-m3") {
            return item(for: "bge-m3-gguf")
        }
        if normalized.contains("nomic-embed") || normalized.contains("nomic-ai") {
            return item(for: "nomic-embed-text-v1.5")
        }
        if normalized.contains("snowflake-arctic") {
            return item(for: "snowflake-arctic-embed-m")
        }
        if normalized.contains("llama-3.2-1b") {
            return item(for: "llama-3.2-1b-instruct")
        }
        if normalized.contains("llama-3.2-3b") {
            return item(for: "llama-3.2-3b-instruct")
        }
        if normalized.contains("qwen-2.5-coder-7b") || normalized.contains("qwen2.5-coder-7b") {
            return item(for: "qwen-2.5-coder-7b")
        }
        if normalized.contains("mistral-7b") {
            return item(for: "mistral-7b-instruct-v0.3")
        }
        if normalized.contains("deepseek-r1-distill-qwen-7b") {
            return item(for: "deepseek-r1-distill-qwen-7b")
        }
        return nil
    }
}
