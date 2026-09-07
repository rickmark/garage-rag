import Foundation

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
}

/// Utility for discovering and parsing Garage configuration files.
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
