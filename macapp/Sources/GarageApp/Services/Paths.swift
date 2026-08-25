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
    static let logsDir: URL = {
        let dir = appSupportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Root of everything vendored into the .app bundle, if we're running packaged.
    private static var bundleResourceRoot: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        return resourceURL
    }

    private static let devPostgresPrefix = URL(fileURLWithPath: "/opt/homebrew/opt/postgresql")
    private static let devPgvectorPrefix = URL(fileURLWithPath: "/opt/homebrew/opt/pgvector")
    private static let devRepoRoot = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("garage"))

    static var isPackaged: Bool {
        guard let root = bundleResourceRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("postgres").path)
    }

    /// Directory containing postgres/initdb/pg_ctl/pg_isready/psql.
    static var postgresBinDir: URL {
        return devPostgresPrefix
    }

    /// Directory postgres should treat as its lib dir (for dynamic loading of extensions).
    static var postgresLibDir: URL {
        if isPackaged, let root = bundleResourceRoot {
            return root.appendingPathComponent("postgres/lib", isDirectory: true)
        }
        return devPostgresPrefix.appendingPathComponent("lib/postgresql", isDirectory: true)
    }

    /// Directory postgres should treat as its share dir (extension SQL/control files).
    static var postgresShareDir: URL {
        return devPostgresPrefix.appendingPathComponent("postgresql", isDirectory: true)
    }

    static func postgresTool(_ name: String) -> URL {
        postgresBinDir.appendingPathComponent(name)
    }

    /// The frozen `garage` CLI binary (packaged) or the venv's `garage` script (dev).
    static var garageCLI: URL {
        let root = bundleResourceRoot!
        return root.appendingPathComponent("garage", isDirectory: false)
    }

    /// The frozen `garage-mcp` binary (packaged) or the venv's script (dev).
    static var garageMCP: URL {
        return devRepoRoot.appendingPathComponent("garage-mcp", isDirectory: false)
    }

    /// Working directory for `garage` CLI invocations, and where its `.env`
    /// lives. In dev mode this is the repo checkout, matching what a
    /// developer running `garage` by hand would get. Packaged builds have no
    /// checkout, so they get a private .env under Application Support instead
    /// (garage reads it via GARAGE_ENV_FILE, not cwd-relative discovery).
    static var garageWorkingDirectory: URL {
        isPackaged ? appSupportDir : devRepoRoot
    }

    static var garageEnvFile: URL {
        garageWorkingDirectory.appendingPathComponent(".env")
    }
}
