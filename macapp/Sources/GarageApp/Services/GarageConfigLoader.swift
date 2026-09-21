import Foundation
import ModelDownloadClient

/// Represents a source registered in the configuration file or the Postgres database.
public struct RegisteredSource: Identifiable, Hashable, Sendable, Codable {
    public var id: String { slug }
    public let slug: String
    public let kind: String
    public let root: String
    public let corpusClass: String
    public let trust: String
    public let allowCloudEnrichment: Bool
    public let enabled: Bool
    public let includeCode: Bool
    public let origin: SourceOrigin
    public var documentCount: Int
    public var expectedElements: Int

    public enum SourceOrigin: String, Sendable, Codable {
        case config = "Config File"
        case database = "Database"
        case both = "Config & Database"
    }

    public init(
        slug: String,
        kind: String = "filesystem",
        root: String,
        corpusClass: String = "document",
        trust: String = "authored",
        allowCloudEnrichment: Bool = false,
        enabled: Bool = true,
        includeCode: Bool = false,
        origin: SourceOrigin = .config,
        documentCount: Int = 0,
        expectedElements: Int = 0
    ) {
        self.slug = slug
        self.kind = kind
        self.root = root
        self.corpusClass = corpusClass
        self.trust = trust
        self.allowCloudEnrichment = allowCloudEnrichment
        self.enabled = enabled
        self.includeCode = includeCode
        self.origin = origin
        self.documentCount = documentCount
        self.expectedElements = expectedElements
    }

    /// Expanded filesystem path, expanding '~' if present.
    public var expandedRootPath: String {
        (root as NSString).expandingTildeInPath
    }

    /// Expanded URL pointing to the source directory or file.
    public var expandedRootURL: URL {
        URL(fileURLWithPath: expandedRootPath)
    }
}

/// Represents a model preset loaded from configuration files, models.json manifest, or built-in presets catalog.
public struct ModelPresetEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String { slug }
    public let name: String
    public let modelId: String?
    public let slug: String
    public let modelRef: String?
    public let provider: String?
    public let nativeDims: Int?
    public let defaultDims: Int?
    public let contextSize: Int?
    public let downloadModelId: String?
    public let downloadFile: String?
    public let sha256: String?
    /// Short human-readable summary of what this model is good for, shown in preset pickers.
    public let description: String?
    /// Example use cases surfaced alongside the description (e.g. "Semantic search", "Chat / Q&A").
    public let useCases: [String]?
    /// Marks this preset as one of the small set of recommended defaults offered when no model is registered yet.
    public let featured: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case modelId = "model_id"
        case slug
        case modelRef = "model_ref"
        case provider
        case nativeDims = "native_dims"
        case defaultDims = "default_dims"
        case contextSize = "context_size"
        case downloadModelId = "download_model_id"
        case downloadFile = "download_file"
        case sha256
        case description
        case useCases = "use_cases"
        case featured
    }

    public init(
        name: String,
        modelId: String? = nil,
        slug: String,
        modelRef: String? = nil,
        provider: String? = "llama_xpc",
        nativeDims: Int? = nil,
        defaultDims: Int? = nil,
        contextSize: Int? = 8192,
        downloadModelId: String? = nil,
        downloadFile: String? = nil,
        sha256: String? = nil,
        description: String? = nil,
        useCases: [String]? = nil,
        featured: Bool = false
    ) {
        self.name = name
        self.modelId = modelId
        self.slug = slug
        self.modelRef = modelRef ?? slug
        self.provider = provider
        self.nativeDims = nativeDims
        self.defaultDims = defaultDims
        self.contextSize = contextSize
        self.downloadModelId = downloadModelId
        self.downloadFile = downloadFile
        self.sha256 = sha256
        self.description = description
        self.useCases = useCases
        self.featured = featured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        slug = try container.decode(String.self, forKey: .slug)
        let decodedModelRef = try container.decodeIfPresent(String.self, forKey: .modelRef)
        modelRef = decodedModelRef ?? slug
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "llama_xpc"
        nativeDims = try container.decodeIfPresent(Int.self, forKey: .nativeDims)
        defaultDims = try container.decodeIfPresent(Int.self, forKey: .defaultDims)
        contextSize = try container.decodeIfPresent(Int.self, forKey: .contextSize) ?? 8192
        downloadModelId = try container.decodeIfPresent(String.self, forKey: .downloadModelId)
        downloadFile = try container.decodeIfPresent(String.self, forKey: .downloadFile)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        useCases = try container.decodeIfPresent([String].self, forKey: .useCases)
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
    }

    public var effectiveDims: Int {
        defaultDims ?? nativeDims ?? 0
    }

    public var downloadURLString: String? {
        if let downloadModelId = downloadModelId, let downloadFile = downloadFile, !downloadModelId.isEmpty, !downloadFile.isEmpty {
            return "https://huggingface.co/\(downloadModelId)/resolve/main/\(downloadFile)"
        }
        if let catalogItem = ModelPresetCatalog.item(forModelIdOrSlug: slug) {
            return catalogItem.downloadUrl
        }
        return nil
    }

    public var effectiveFilename: String? {
        if let downloadFile = downloadFile, !downloadFile.isEmpty {
            return downloadFile
        }
        if let catalogItem = ModelPresetCatalog.item(forModelIdOrSlug: slug) {
            return catalogItem.filename
        }
        return nil
    }

    public var isEmbeddingModel: Bool {
        if let dims = defaultDims ?? nativeDims, dims > 0 {
            return true
        }
        let lower = (name + " " + slug).lowercased()
        return lower.contains("embed") || lower.contains("bge") || lower.contains("arctic")
    }
}

/// JSON representation of the configuration file.
public struct GarageConfigFile: Codable {
    public struct SourceEntry: Codable {
        public let slug: String
        public let root: String
        public let kind: String?
        public let corpusClass: String?
        public let trust: String?
        public let includeCode: Bool?
        public let allowCloudEnrichment: Bool?
        public let enabled: Bool?

        enum CodingKeys: String, CodingKey {
            case slug
            case root
            case kind
            case corpusClass = "class"
            case trust
            case includeCode = "include_code"
            case allowCloudEnrichment = "allow_cloud_enrichment"
            case enabled
        }
    }

    public let sources: [SourceEntry]?
    public let models: [ModelPresetEntry]?
}

/// The on-disk shape of `models.json`: presets grouped by what they're used for,
/// rather than one flat list. `text_embedding` feeds the embedding model
/// picker; `fact_distil` feeds the (generative) fact-distillation model picker.
private struct ModelsManifest: Codable {
    let textEmbedding: [ModelPresetEntry]?
    let factDistil: [ModelPresetEntry]?

    enum CodingKeys: String, CodingKey {
        case textEmbedding = "text_embedding"
        case factDistil = "fact_distil"
    }
}

/// Utility for discovering and parsing Garage configuration files and model presets.
public enum GarageConfigLoader {
    /// Candidate file URLs where `garage.json` / `.garage.json` might reside.
    public static var candidateConfigFiles: [URL] {
        var paths: [URL] = []

        // 1. Current working directory for garage CLI
        let workDir = Paths.garageWorkingDirectory.appendingPathComponent("garage.json")
        paths.append(workDir)

        // 2. Project / process current working directory
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("garage.json")
        if cwd.path != workDir.path {
            paths.append(cwd)
        }

        // 3. User home directory ~/.garage.json
        let homeDotfile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".garage.json")
        paths.append(homeDotfile)

        // 4. ~/.config/garage/garage.json
        let homeXDG = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("garage")
            .appendingPathComponent("garage.json")
        paths.append(homeXDG)

        // 5. Application Support directory
        let appSupport = Paths.appSupportDir.appendingPathComponent("garage.json")
        paths.append(appSupport)

        return paths
    }

    /// Finds the first existing configuration file path.
    public static func findExistingConfigFile() -> URL? {
        for url in candidateConfigFiles {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Built-in fallback presets catalog.
    public static let defaultPresets: [ModelPresetEntry] = [
        ModelPresetEntry(
            name: "BGE-M3 (Embeddings)",
            modelId: "BAAI/bge-m3",
            slug: "bge-m3",
            modelRef: "bge-m3",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192,
            downloadModelId: "gpustack/bge-m3-GGUF",
            downloadFile: "bge-m3-Q8_0.gguf",
            sha256: "950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167",
            description: "Strong general-purpose multilingual embedding model with a long context window. A solid default for hybrid document search.",
            useCases: ["Semantic search", "Hybrid retrieval", "Multilingual corpora"],
            featured: true
        ),
        ModelPresetEntry(
            name: "Nomic Embed Text",
            modelId: "nomic-ai/nomic-embed-text-v1.5",
            slug: "nomic-embed-text",
            modelRef: "nomic-embed-text",
            provider: "llama_xpc",
            nativeDims: 768,
            defaultDims: 768,
            contextSize: 8192,
            downloadModelId: "nomic-ai/nomic-embed-text-v1.5-GGUF",
            downloadFile: "nomic-embed-text-v1.5.Q8_0.gguf",
            sha256: "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7",
            description: "Efficient English-focused embedding model with good accuracy per dimension. Fast to run on modest hardware.",
            useCases: ["Semantic search", "Personal document archives"],
            featured: true
        ),
        ModelPresetEntry(
            name: "mxbai Embed XSmall",
            modelId: "mixedbread-ai/mxbai-embed-xsmall-v1",
            slug: "mxbai-embed-xsmall",
            modelRef: "mxbai-embed-xsmall",
            provider: "llama_xpc",
            nativeDims: 384,
            defaultDims: 384,
            contextSize: 512,
            downloadModelId: "mixedbread-ai/mxbai-embed-xsmall-v1",
            downloadFile: "gguf/mxbai-embed-xsmall-v1-q8_0.gguf",
            sha256: "21f9f06af9e4e895fcdcbf6c0d57ca1996fe22da54ecb6cc5f7733d785412d44",
            description: "Compact, low-memory embedding model that's quick to download and embed with. Ideal for a lightweight first-time setup.",
            useCases: ["Quick start / low-resource machines", "Semantic search"],
            featured: true
        ),
        ModelPresetEntry(
            name: "mxbai Embed Large",
            modelId: "mixedbread-ai/mxbai-embed-large",
            slug: "mxbai-embed-large",
            modelRef: "mxbai-embed-large",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192
        ),
        ModelPresetEntry(
            name: "Embedding Gemma",
            modelId: "google/embeddinggemma-2b",
            slug: "embeddinggemma",
            modelRef: "embeddinggemma",
            provider: "llama_xpc",
            nativeDims: 768,
            defaultDims: 768,
            contextSize: 8192,
            downloadModelId: "unsloth/embeddinggemma-300m-GGUF",
            downloadFile: "embeddinggemma-300M-Q8_0.gguf",
            sha256: "a0f7b4e13c397a6e1b32c2de75b1f65a14c92ec524d5f674d94a4290a1c4969b"
        ),
        ModelPresetEntry(
            name: "Snowflake Arctic Embed 2",
            modelId: "Snowflake/snowflake-arctic-embed-m-v2.0",
            slug: "snowflake-arctic-embed2",
            modelRef: "snowflake-arctic-embed2",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192,
            downloadModelId: "ChristianAzinn/snowflake-arctic-embed-m-gguf",
            downloadFile: "snowflake-arctic-embed-m-Q8_0.GGUF",
            sha256: "670a415c5b42b1b317eb7116a154c08e7b7a69550d088f3b46520d8b3d0741a8"
        ),
        ModelPresetEntry(
            name: "Qwen 3 Embedding 0.6B",
            modelId: "Qwen/Qwen3-Embedding-0.6B",
            slug: "qwen3-embedding-0.6b",
            modelRef: "qwen3-embedding-0.6b",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192
        ),
        ModelPresetEntry(
            name: "Qwen 3 Embedding 4B",
            modelId: "Qwen/Qwen3-Embedding-4B",
            slug: "qwen3-embedding-4b",
            modelRef: "qwen3-embedding-4b",
            provider: "llama_xpc",
            nativeDims: 2560,
            defaultDims: 2560,
            contextSize: 8192
        ),
        ModelPresetEntry(
            name: "Qwen 3 Embedding 8B",
            modelId: "Qwen/Qwen3-Embedding-8B",
            slug: "qwen3-embedding-8b",
            modelRef: "qwen3-embedding-8b",
            provider: "llama_xpc",
            nativeDims: 4096,
            defaultDims: 4000,
            contextSize: 32768
        ),
        ModelPresetEntry(
            name: "Llama 3.2 1B (Instruct)",
            modelId: "meta-llama/Llama-3.2-1B-Instruct",
            slug: "llama-3.2-1b-instruct",
            modelRef: "llama-3.2-1b-instruct",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192,
            downloadModelId: "bartowski/Llama-3.2-1B-Instruct-GGUF",
            downloadFile: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83"
        ),
        ModelPresetEntry(
            name: "Llama 3.2 3B (Instruct)",
            modelId: "meta-llama/Llama-3.2-3B-Instruct",
            slug: "llama-3.2-3b-instruct",
            modelRef: "llama-3.2-3b-instruct",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192,
            downloadModelId: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            downloadFile: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff"
        ),
        ModelPresetEntry(
            name: "Qwen 2.5 7B (Coder)",
            modelId: "Qwen/Qwen2.5-Coder-7B-Instruct",
            slug: "qwen-2.5-coder-7b",
            modelRef: "qwen-2.5-coder-7b",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 16384,
            downloadModelId: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
            downloadFile: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf",
            sha256: "1664fccab734674a50763490a8c6931b70e3f2f8ec10031b54806d30e5f956b6"
        ),
        ModelPresetEntry(
            name: "Mistral 7B (Instruct)",
            modelId: "mistralai/Mistral-7B-Instruct-v0.3",
            slug: "mistral-7b-instruct",
            modelRef: "mistral-7b-instruct",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192,
            downloadModelId: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            downloadFile: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            sha256: "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6"
        ),
        ModelPresetEntry(
            name: "DeepSeek R1 Distill Qwen 7B",
            modelId: "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
            slug: "deepseek-r1-distill-qwen-7b",
            modelRef: "deepseek-r1-distill-qwen-7b",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192,
            downloadModelId: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF",
            downloadFile: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
            sha256: "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b"
        ),
        ModelPresetEntry(
            name: "NVIDIA Llama-Embed-Nemotron-8B",
            modelId: "NVIDIA/Llama-Embed-Nemotron-8B",
            slug: "llama-embed-nemotron-8b",
            modelRef: "llama-embed-nemotron-8b",
            provider: "llama_xpc",
            nativeDims: 4096,
            defaultDims: 4096,
            contextSize: 8192,
            downloadModelId: "mradermacher/llama-embed-nemotron-8b-GGUF",
            downloadFile: "llama-embed-nemotron-8b.Q8_0.gguf",
            sha256: "951f506d4d8c93c02abe586520076e61b4b8e5501f63bcda05cde610c102cf42"
        ),
        ModelPresetEntry(
            name: "Microsoft Harrier-oss-v1-0.6b",
            modelId: "microsoft/harrier-oss-v1-0.6b",
            slug: "harrier-oss-v1-0.6b",
            modelRef: "harrier-oss-v1-0.6b",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192
        ),
    ]

    /// Built-in fallback presets for fact distillation (used when models.json is missing).
    public static let defaultFactDistilPresets: [ModelPresetEntry] = [
        ModelPresetEntry(
            name: "Gemma 2 2B Instruct",
            modelId: "google/gemma-2-2b-it",
            slug: "gemma2-2b",
            modelRef: "gemma2-2b",
            provider: "llama_xpc",
            nativeDims: nil,
            defaultDims: nil,
            contextSize: 8192,
            downloadModelId: "bartowski/gemma-2-2b-it-GGUF",
            downloadFile: "gemma-2-2b-it-Q4_K_M.gguf",
            sha256: "e0aee85060f168f0f2d8473d7ea41ce2f3230c1bc1374847505ea599288a7787",
            description: "Compact instruction-tuned model used to distill documents into atomic facts for the enrichment pipeline.",
            useCases: ["Fact extraction / distillation"],
            featured: true
        ),
    ]

    /// Loads text-embedding model presets from models.json or configuration files.
    public static func loadModelPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadModelManifest(fileURL: fileURL).textEmbedding ?? defaultPresets
    }

    /// Loads fact-distillation model presets (generative models used to glean facts
    /// out of documents) from models.json's `fact_distil` section.
    public static func loadFactDistilPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        loadModelManifest(fileURL: fileURL).factDistil ?? defaultFactDistilPresets
    }

    /// Resolves models.json (or a candidate config file) into its two preset
    /// groups. Returns `nil` for a group that no source provided at all, so
    /// callers can distinguish "found the file, group was empty" from
    /// "never found a file" and fall back to built-in defaults only for the
    /// latter.
    private static func loadModelManifest(fileURL: URL?) -> (textEmbedding: [ModelPresetEntry]?, factDistil: [ModelPresetEntry]?) {
        var candidates: [URL] = []
        if let explicit = fileURL {
            candidates.append(explicit)
        }
        candidates.append(Paths.modelsJSON)
        candidates.append(contentsOf: candidateConfigFiles)

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let manifest = decodeModelManifest(from: url) {
                return manifest
            }
        }

        return (nil, nil)
    }

    private static func decodeModelManifest(from url: URL) -> (textEmbedding: [ModelPresetEntry]?, factDistil: [ModelPresetEntry]?)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()

        // 1. Current models.json shape: presets grouped by use (text_embedding / fact_distil).
        if let manifest = try? decoder.decode(ModelsManifest.self, from: data),
           !(manifest.textEmbedding ?? []).isEmpty || !(manifest.factDistil ?? []).isEmpty {
            return (manifest.textEmbedding, manifest.factDistil)
        }

        // 2. Legacy flat array of ModelPresetEntry (pre-grouping models.json).
        if let list = try? decoder.decode([ModelPresetEntry].self, from: data), !list.isEmpty {
            return (list, nil)
        }

        // 3. garage.json with an embedded `models` array.
        if let config = try? decoder.decode(GarageConfigFile.self, from: data), let models = config.models, !models.isEmpty {
            return (models, nil)
        }

        return nil
    }

    /// Parses sources declared in configuration files.
    public static func loadSourcesFromConfig(fileURL: URL? = nil) -> [RegisteredSource] {
        let targets = fileURL.map { [$0] } ?? candidateConfigFiles

        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let config = try JSONDecoder().decode(GarageConfigFile.self, from: data)
                if let sources = config.sources, !sources.isEmpty {
                    return sources.map { entry in
                        RegisteredSource(
                            slug: entry.slug,
                            kind: entry.kind ?? "filesystem",
                            root: entry.root,
                            corpusClass: entry.corpusClass ?? "document",
                            trust: entry.trust ?? "authored",
                            allowCloudEnrichment: entry.allowCloudEnrichment ?? false,
                            enabled: entry.enabled ?? true,
                            includeCode: entry.includeCode ?? false,
                            origin: .config
                        )
                    }
                }
            } catch {
                // Ignore parse errors or try next candidate
                continue
            }
        }

        return []
    }
}
