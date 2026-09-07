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
        origin: SourceOrigin = .config
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
        downloadFile: String? = nil
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
            downloadModelId: "CompendiumLabs/bge-m3-GGUF",
            downloadFile: "bge-m3-Q8_0.gguf"
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
            downloadFile: "nomic-embed-text-v1.5.Q8_0.gguf"
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
            contextSize: 8192
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
            downloadFile: "snowflake-arctic-embed-m.Q8_0.gguf"
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
            downloadFile: "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
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
            downloadFile: "Llama-3.2-3B-Instruct-Q4_K_M.gguf"
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
            downloadFile: "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf"
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
            downloadFile: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
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
            downloadFile: "llama-embed-nemotron-8b.Q8_0.gguf"
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

    /// Loads model presets from models.json or configuration files.
    public static func loadModelPresets(fileURL: URL? = nil) -> [ModelPresetEntry] {
        if let explicit = fileURL, FileManager.default.fileExists(atPath: explicit.path) {
            if let parsed = decodeModelPresets(from: explicit), !parsed.isEmpty {
                return parsed
            }
        }

        // Try standard models.json path
        let modelsPath = Paths.modelsJSON
        if FileManager.default.fileExists(atPath: modelsPath.path) {
            if let parsed = decodeModelPresets(from: modelsPath), !parsed.isEmpty {
                return parsed
            }
        }

        // Try candidate config files
        for url in candidateConfigFiles {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let parsed = decodeModelPresets(from: url), !parsed.isEmpty {
                return parsed
            }
        }

        return defaultPresets
    }

    private static func decodeModelPresets(from url: URL) -> [ModelPresetEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()

        // 1. Try decoding array of ModelPresetEntry directly (e.g. models.json)
        if let list = try? decoder.decode([ModelPresetEntry].self, from: data), !list.isEmpty {
            return list
        }

        // 2. Try decoding GarageConfigFile with models array
        if let config = try? decoder.decode(GarageConfigFile.self, from: data), let models = config.models, !models.isEmpty {
            return models
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
