import Foundation
import OSLog
import PythonKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "XPCSitePathSetup")

/// Compatibility facade over `GaragePythonRuntime`.
///
/// Historically this configured `sys.path` after the fact; the interpreter is now started through the
/// PyConfig API with `home`, `stdlib`, `lib-dynload` and `site-packages` set up front (see
/// `GaragePythonRuntime`). `setupSitePath()` simply triggers that initialization.
public struct XPCSitePathSetup {
    /// Initializes the bundled Python environment if it has not been started yet.
    @discardableResult
    public static func setupSitePath() -> Bool {
        logger.info("XPCSitePathSetup: initializing bundled Python for '\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)'...")
        switch GaragePythonRuntime.shared.initializeIfNeeded() {
        case .success(let env):
            logger.info("XPCSitePathSetup: Python ready (home: \(env.home.path, privacy: .public))")
            return true
        case .failure(let error):
            logger.error("XPCSitePathSetup: Python initialization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    /// Normalizes database URLs to ensure psycopg is used.
    public static func ensurePsycopgDatabaseURL(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        
        if trimmed.hasPrefix("postgresql+psycopg://") {
            return trimmed
        }
        if trimmed.hasPrefix("postgresql://") {
            let suffix = trimmed.dropFirst("postgresql://".count)
            return "postgresql+psycopg://\(suffix)"
        }
        if trimmed.hasPrefix("postgres://") {
            let suffix = trimmed.dropFirst("postgres://".count)
            return "postgresql+psycopg://\(suffix)"
        }
        return trimmed
    }
}
