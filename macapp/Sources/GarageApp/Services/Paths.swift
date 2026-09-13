import Foundation

/// Resolves where the Postgres install and the frozen `garage` CLI live.
///
/// Packaged builds (produced by Scripts/build-app.sh) vendor both under the
/// app bundle's Resources/ so the app runs with zero prerequisites. When run
/// unpackaged (`swift run`, during development) there is no bundle to vendor
/// into, so we fall back to the Homebrew install and the repo's uv venv —
/// the same tools the README already asks a developer to have.
enum Paths {
    static let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GarageApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let pgDataDir = appSupportDir.appendingPathComponent("pgdata", isDirectory: true)
    static let pgSocketDir = appSupportDir.appendingPathComponent("sockets", isDirectory: true)
    static let modelsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let logsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Root of everything vendored into the .app bundle, if we're running packaged.
    private static var root: URL {
        return Bundle.main.resourceURL!
    }

    private static let postgresPrefix = URL(fileURLWithPath: "/opt/homebrew/opt/postgresql")
    private static let devRepoRoot: URL = {
        let candidate1 = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Developer/garage"))
        if FileManager.default.fileExists(atPath: candidate1.path) {
            return candidate1
        }
        return URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("garage"))
    }()

    static var isPackaged: Bool {
        return true
    }

    static var postgresDir: URL {
        return root.appendingPathComponent("postgres", isDirectory: true)
    }

    /// Directory containing the SQL schema bundled with the application.
    static var schemaDir: URL {
        return root.appendingPathComponent("schema", isDirectory: true)
    }

    /// Path to models.json manifest file.
    static var modelsJSON: URL {
        if let resourceURL = Bundle.main.url(forResource: "models", withExtension: "json") {
            return resourceURL
        }
        if let resourceURL = Bundle.main.url(forResource: "models.json", withExtension: nil) {
            return resourceURL
        }
        let bundled = root.appendingPathComponent("models.json")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let bundledDataModels = root.appendingPathComponent("data/models/models.json")
        if FileManager.default.fileExists(atPath: bundledDataModels.path) {
            return bundledDataModels
        }
        let devPath = devRepoRoot.appendingPathComponent("data/models/models.json")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return bundled
    }

    /// Directory containing postgres/initdb/pg_ctl/pg_isready/psql.
    static var postgresBinDir: URL {
        return root.appendingPathComponent("postgres/bin", isDirectory: true)
    }

    /// Directory postgres should treat as its lib dir (for dynamic loading of extensions).
    static var postgresLibDir: URL {
        return root.appendingPathComponent("postgres/lib", isDirectory: true)
    }

    /// Directory postgres should treat as its share dir (extension SQL/control files).
    static var postgresShareDir: URL {
        return root.appendingPathComponent("postgres/share", isDirectory: true)
    }

    static func postgresTool(_ name: String) -> URL {
        postgresBinDir.appendingPathComponent(name)
    }

    /// The frozen `garage` CLI binary (packaged) or the venv's `garage` script (dev).
    static var garageCLI: URL {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "garage"),
           FileManager.default.fileExists(atPath: aux.path) {
            return aux
        }
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("garage"),
           FileManager.default.fileExists(atPath: execURL.path) {
            return execURL
        }
        let bundled = root.appendingPathComponent("garage", isDirectory: false)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let res = Bundle.main.url(forResource: "garage", withExtension: nil),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        let devCandidates = [
            devRepoRoot.appendingPathComponent(".venv/bin/garage"),
            devRepoRoot.appendingPathComponent("bazel-bin/garage_python/garage"),
            URL(fileURLWithPath: "/opt/homebrew/bin/garage"),
            URL(fileURLWithPath: "/usr/local/bin/garage"),
        ]
        for candidate in devCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return bundled
    }

    /// The frozen `garage-mcp` binary (packaged) or the venv's script (dev).
    static var garageMCP: URL {
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "garage-mcp"),
           FileManager.default.fileExists(atPath: aux.path) {
            return aux
        }
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("garage-mcp"),
           FileManager.default.fileExists(atPath: execURL.path) {
            return execURL
        }
        let bundled = root.appendingPathComponent("garage-mcp", isDirectory: false)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        if let res = Bundle.main.url(forResource: "garage-mcp", withExtension: nil),
           FileManager.default.fileExists(atPath: res.path) {
            return res
        }
        let devCandidates = [
            devRepoRoot.appendingPathComponent(".venv/bin/garage-mcp"),
            devRepoRoot.appendingPathComponent("bazel-bin/garage_python/garage-mcp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/garage-mcp"),
            URL(fileURLWithPath: "/usr/local/bin/garage-mcp"),
        ]
        for candidate in devCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return bundled
    }

    /// Working directory for `garage` CLI invocations, and where its `.env`
    /// lives. In dev mode this is the repo checkout, matching what a
    /// developer running `garage` by hand would get. Packaged builds have no
    /// checkout, so they get a private .env under Application Support instead
    /// (garage reads it via GARAGE_ENV_FILE, not cwd-relative discovery).
    static var garageWorkingDirectory: URL {
        isPackaged ? appSupportDir : devRepoRoot
    }
}
