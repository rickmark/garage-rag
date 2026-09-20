import Foundation
import PythonKit

/// Simple site-python path setup - no dynamic library loading.
/// Only configures Python's sys.path to include the bundled site-packages.
public struct XPCSitePathSetup {
    /// Sets up Python's sys.path with the bundled site-packages.
    /// This is used instead of dynamic library loading - PythonKit uses static linking.
    public static func setupSitePath() {
        PythonInterface.setupPythonHome()
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
