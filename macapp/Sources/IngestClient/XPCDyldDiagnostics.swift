import Foundation
import OSLog
import Darwin

private let logger = Logger(subsystem: "me.rickmark.garage", category: "XPCDyldDiagnostics")

/// Detailed diagnostic report for an XPC helper service, specifically checking for dyld loading,
/// crash logs, binary presence, and runtime environment problems.
public struct XPCServiceDiagnosticReport: Sendable {
    public let serviceIdentifier: String
    public let bundlePath: String?
    public let executablePath: String?
    public let bundleExists: Bool
    public let executableExists: Bool
    public let isExecutable: Bool
    public let dyldErrorDetails: String?
    public let recentCrashReport: String?
    public let recentLogEntries: [String]
    public let environmentSummary: String?

    public init(
        serviceIdentifier: String,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        bundleExists: Bool = false,
        executableExists: Bool = false,
        isExecutable: Bool = false,
        dyldErrorDetails: String? = nil,
        recentCrashReport: String? = nil,
        recentLogEntries: [String] = [],
        environmentSummary: String? = nil
    ) {
        self.serviceIdentifier = serviceIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.bundleExists = bundleExists
        self.executableExists = executableExists
        self.isExecutable = isExecutable
        self.dyldErrorDetails = dyldErrorDetails
        self.recentCrashReport = recentCrashReport
        self.recentLogEntries = recentLogEntries
        self.environmentSummary = environmentSummary
    }

    /// Short human-readable summary for error messages and UI display.
    public var shortSummary: String {
        if let dyld = dyldErrorDetails {
            return "dyld error: \(dyld)"
        }
        if let crash = recentCrashReport {
            return "crash detected: \(crash)"
        }
        if !bundleExists {
            return "XPC bundle not found on disk"
        }
        if !executableExists {
            return "XPC executable not found inside bundle"
        }
        if !isExecutable {
            return "XPC executable does not have execute permissions"
        }
        if !recentLogEntries.isEmpty {
            return recentLogEntries.last ?? "service reported errors"
        }
        return "service process unreachable or terminated unexpectedly"
    }

    /// Complete diagnostic summary formatted for logging and debugging.
    public var formattedSummary: String {
        var lines: [String] = []
        lines.append("=== XPC Service Diagnostic Report: \(serviceIdentifier) ===")
        lines.append("Bundle Path: \(bundlePath ?? "not found") (exists: \(bundleExists))")
        lines.append("Executable Path: \(executablePath ?? "not found") (exists: \(executableExists), executable: \(isExecutable))")

        if let dyld = dyldErrorDetails {
            lines.append("dyld Issue: \(dyld)")
        }
        if let crash = recentCrashReport {
            lines.append("Crash Report:\n  \(crash.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        if let env = environmentSummary {
            lines.append("Environment Diagnostics:\n  \(env.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        if !recentLogEntries.isEmpty {
            lines.append("Recent Log Messages:")
            for entry in recentLogEntries.suffix(5) {
                lines.append("  - \(entry)")
            }
        }
        lines.append("==========================================================")
        return lines.joined(separator: "\n")
    }
}

/// Utility for diagnosing dyld loading issues, crashes, and startup failures for XPC helper services.
public struct XPCDyldDiagnostics: Sendable {

    /// Known mapping from service bundle IDs to default executable names.
    public static let knownServiceExecutableMap: [String: String] = [
        "me.rickmark.garage-rag.ingest-xpc": "GarageIngestXPCService",
        "ingest-xpc": "GarageIngestXPCService",
        "me.rickmark.garage-rag.embed-xpc": "GarageEmbedXPCService",
        "embed-xpc": "GarageEmbedXPCService",
        "me.rickmark.garage-rag.llama-xpc": "LlamaXPCService",
        "llama-xpc": "LlamaXPCService",
        "me.rickmark.garage-rag.model-download-xpc": "ModelDownloadXPCService",
        "model-download-xpc": "ModelDownloadXPCService",
        "me.rickmark.garage-rag.mcp-server-xpc": "GarageMCPServerService",
        "mcp-server-xpc": "GarageMCPServerService",
        "me.rickmark.garage-rag.xpc": "GarageXPCService",
        "garage-xpc": "GarageXPCService"
    ]

    /// Inspects an XPC service on disk and system logs to diagnose dyld or launch issues.
    public static func diagnoseService(
        bundleId: String,
        executableName: String? = nil
    ) -> XPCServiceDiagnosticReport {
        let execName = executableName ?? knownServiceExecutableMap[bundleId] ?? (bundleId.components(separatedBy: ".").last ?? bundleId)
        let (bundleURL, execURL) = locateServiceBundle(bundleId: bundleId, executableName: execName)

        let fileManager = FileManager.default
        let bundleExists = bundleURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let execPath = execURL?.path
        let execExists = execPath.map { fileManager.fileExists(atPath: $0) } ?? false
        let isExec = execPath.map { access($0, X_OK) == 0 } ?? false

        // Check for recent crash reports or dyld abort logs
        let crashReport = findRecentCrashReport(executableName: execName, maxAge: 60.0)
        let dyldError = extractDyldError(from: crashReport)

        // Read recent system / os_log entries for the service
        let recentLogs = readRecentLogs(forExecutableName: execName, bundleId: bundleId)

        // Gather environment diagnostics
        let envSummary = gatherEnvironmentDiagnostics()

        let report = XPCServiceDiagnosticReport(
            serviceIdentifier: bundleId,
            bundlePath: bundleURL?.path,
            executablePath: execPath,
            bundleExists: bundleExists,
            executableExists: execExists,
            isExecutable: isExec,
            dyldErrorDetails: dyldError,
            recentCrashReport: crashReport,
            recentLogEntries: recentLogs,
            environmentSummary: envSummary
        )

        logger.info("\(report.formattedSummary, privacy: .public)")
        return report
    }

    /// Enriches an XPC communication error with dyld and process launch diagnostics.
    public static func enrichXPCError(
        _ error: Error,
        forServiceBundleId bundleId: String,
        executableName: String? = nil
    ) -> NSError {
        let report = diagnoseService(bundleId: bundleId, executableName: executableName)
        let nsError = error as NSError
        var userInfo = nsError.userInfo

        let augmentedMessage = "\(nsError.localizedDescription) [XPC Diagnostics: \(report.shortSummary)]"
        userInfo[NSLocalizedDescriptionKey] = augmentedMessage
        userInfo[NSLocalizedFailureReasonErrorKey] = report.formattedSummary
        userInfo["XPCDiagnosticShortSummary"] = report.shortSummary
        userInfo["XPCDiagnosticReport"] = report.formattedSummary

        if let dyld = report.dyldErrorDetails {
            userInfo["DyldError"] = dyld
        }
        if let crash = report.recentCrashReport {
            userInfo["CrashReport"] = crash
        }

        return NSError(
            domain: nsError.domain.isEmpty ? "me.rickmark.garage.xpc" : nsError.domain,
            code: nsError.code,
            userInfo: userInfo
        )
    }

    /// Ensures a database URL starts with postgresql+psycopg://.
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
        if let range = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<range.lowerBound])
            let rest = String(trimmed[range.upperBound...])
            if scheme.hasPrefix("postgres") || scheme.hasPrefix("postgresql") {
                return "postgresql+psycopg://\(rest)"
            }
        }
        return trimmed
    }

    /// Sets up the Postgres / libpq environment variables and loads libpq if present.
    @discardableResult
    public static func setupPostgresEnvironment() -> String? {
        if let dbURL = ProcessInfo.processInfo.environment["GARAGE_DATABASE_URL"], !dbURL.isEmpty {
            let normalized = ensurePsycopgDatabaseURL(dbURL)
            if normalized != dbURL {
                setenv("GARAGE_DATABASE_URL", normalized, 1)
            }
        }

        var candidatePaths: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            candidatePaths.append(envPath)
        }

        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDir = execURL.deletingLastPathComponent()
        let bundleURL = Bundle.main.bundleURL
        let isXPC = bundleURL.pathExtension == "xpc"
        let parentAppContents = isXPC ? bundleURL.deletingLastPathComponent().deletingLastPathComponent() : bundleURL.appendingPathComponent("Contents")

        // 1. Primary path from Contents/MacOS/<binary>: ../../Resources/postgres/lib/libpq.dylib
        candidatePaths.append(execURL.appendingPathComponent("../../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)

        if let resURL = Bundle.main.resourceURL {
            candidatePaths.append(resURL.appendingPathComponent("postgres/lib/libpq.dylib").path)
            candidatePaths.append(resURL.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
        }

        candidatePaths.append(parentAppContents.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib").path)

        candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.dylib").path)
        candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
        candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.dylib").path)
        candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.5.dylib").path)

        // Fallbacks
        candidatePaths.append("/Applications/Garage.app/Contents/Resources/postgres/lib/libpq.dylib")
        candidatePaths.append("/Applications/Garage.app/Contents/Resources/postgres/lib/libpq.5.dylib")
        candidatePaths.append("/opt/homebrew/opt/libpq/lib/libpq.dylib")
        candidatePaths.append("/opt/homebrew/opt/libpq/lib/libpq.5.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@18/libpq.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@18/libpq.5.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@17/libpq.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@17/libpq.5.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@16/libpq.dylib")
        candidatePaths.append("/opt/homebrew/lib/postgresql@16/libpq.5.dylib")
        candidatePaths.append("/opt/homebrew/lib/libpq.dylib")
        candidatePaths.append("/opt/homebrew/lib/libpq.5.dylib")
        candidatePaths.append("/usr/local/opt/libpq/lib/libpq.dylib")
        candidatePaths.append("/usr/local/opt/libpq/lib/libpq.5.dylib")
        candidatePaths.append("/usr/local/lib/libpq.dylib")
        candidatePaths.append("/usr/local/lib/libpq.5.dylib")

        let (selectedPath, _) = diagnosePostgresLibraryLoading(candidatePaths: candidatePaths)
        if let path = selectedPath {
            setenv("GARAGE_LIBPQ_PATH", path, 1)
            let libDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            setenv("DYLD_FALLBACK_LIBRARY_PATH", libDir, 1)
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
            return path
        }
        return nil
    }

    /// Generates candidate paths for locating the Python runtime dynamic library.
    public static func defaultPythonCandidatePaths() -> [String] {
        var candidatePaths: [String] = []
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDir = execURL.deletingLastPathComponent()
        let bundleURL = Bundle.main.bundleURL
        let isXPC = bundleURL.pathExtension == "xpc"
        let parentAppContents = isXPC ? bundleURL.deletingLastPathComponent().deletingLastPathComponent() : bundleURL.appendingPathComponent("Contents")

        // 1. Primary paths from Contents/MacOS/<binary> or Contents/XPCServices/<service>.xpc/Contents/MacOS/<binary>
        // Main app / helper binary relative (../../Frameworks)
        candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/libpython3.13.dylib").standardizedFileURL.path)

        // XPC service relative: Contents/XPCServices/<service>.xpc/Contents/MacOS/<exec> (../../../../Frameworks)
        candidatePaths.append(execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Python").standardizedFileURL.path)
        candidatePaths.append(execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/3.13/lib/libpython3.13.dylib").standardizedFileURL.path)

        // Additional relative candidate traversals
        candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
        candidatePaths.append(binDir.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)

        // 2. Bundle frameworks / private frameworks
        if let privFwURL = Bundle.main.privateFrameworksURL {
            candidatePaths.append(privFwURL.appendingPathComponent("Python.framework/Versions/Current/Python").path)
            candidatePaths.append(privFwURL.appendingPathComponent("Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(privFwURL.appendingPathComponent("Python.framework/Python").path)
        }
        if let resURL = Bundle.main.resourceURL {
            candidatePaths.append(resURL.appendingPathComponent("python_3_13/Python.framework/Versions/Current/Python").path)
            candidatePaths.append(resURL.appendingPathComponent("python_3_13/Python.framework/Versions/3.13/Python").path)
            candidatePaths.append(resURL.appendingPathComponent("python_3_13/Python.framework/Python").path)
        }

        // 3. Parent app contents (from XPC service or app bundle)
        candidatePaths.append(parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Frameworks/Python.framework/Python").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/libpython3.13.dylib").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(parentAppContents.appendingPathComponent("Resources/python_3_13/Python.framework/Python").path)

        // 4. Binary relative
        candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
        candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
        candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/Current/Python").path)
        candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/3.13/Python").path)

        // 5. System / Homebrew fallbacks
        candidatePaths.append("/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Applications/Garage.app/Contents/Frameworks/Python.framework/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/Current/Python")
        candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.13/Python")

        return candidatePaths
    }

    /// Sets DYLD_FRAMEWORK_PATH and DYLD_FALLBACK_FRAMEWORK_PATH to the enclosing directory of Python.framework.
    private static func configureFrameworkEnvironment(forPythonPath path: String) {
        var current = URL(fileURLWithPath: path)
        while current.path != "/" && current.pathExtension != "framework" {
            current = current.deletingLastPathComponent()
        }
        if current.pathExtension == "framework" {
            let frameworkContainerDir = current.deletingLastPathComponent().path
            setenv("DYLD_FALLBACK_FRAMEWORK_PATH", frameworkContainerDir, 1)
            setenv("DYLD_FRAMEWORK_PATH", frameworkContainerDir, 1)
        }
    }

    /// Sets up the Python library environment variables and resolves the active dynamic Python library.
    @discardableResult
    public static func setupPythonEnvironment() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
           FileManager.default.fileExists(atPath: envPath) {
            let handle = dlopen(envPath, RTLD_LAZY | RTLD_LOCAL)
            if let handle = handle {
                dlclose(handle)
                configureFrameworkEnvironment(forPythonPath: envPath)
                _ = dlopen(envPath, RTLD_NOW | RTLD_GLOBAL)
                return envPath
            }
        }

        let candidatePaths = defaultPythonCandidatePaths()
        let (selectedPath, _) = diagnosePythonLibraryLoading(candidatePaths: candidatePaths)
        if let path = selectedPath {
            setenv("PYTHON_LIBRARY", path, 1)
            configureFrameworkEnvironment(forPythonPath: path)
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
            return path
        }
        return nil
    }

    /// Sets up environment variables, dynamically links Python.framework via dlopen, and configures sys.path prior to any PythonKit calls.
    @discardableResult
    public static func initializePythonRuntime() throws -> String {
        setupPostgresEnvironment()
        guard let pythonLib = setupPythonEnvironment() else {
            let (_, diagnostics) = diagnosePythonLibraryLoading(candidatePaths: defaultPythonCandidatePaths())
            let diagSummary = diagnostics.joined(separator: "\n")
            var dyldError = ""
            if let errCStr = dlerror() {
                dyldError = "\ndyld error: \(String(cString: errCStr))"
            }
            throw NSError(
                domain: "me.rickmark.garage.python",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not resolve or link Python.framework in Contents/Frameworks dynamically.\(dyldError)",
                    "Diagnostics": diagSummary
                ]
            )
        }

        #if canImport(PythonKit)
        try PythonLibrary.loadLibrary()
        let sys = try Python.attemptImport("sys")
        let (libPaths, spPaths) = getPythonLibAndSitePackagesPaths()
        for lib in libPaths {
            sys.path.insert(0, lib)
        }
        for sp in spPaths {
            sys.path.insert(0, sp)
        }
        if let resURL = Bundle.main.resourceURL {
            sys.path.insert(0, resURL.path)
        }
        ensureStandardStreams()
        #endif

        return pythonLib
    }

    /// Configures standard streams (stdin, stdout, stderr) in Python's sys module so that
    /// standard output and error are properly connected to file descriptors 0, 1, and 2.
    public static func ensureStandardStreams() {
        #if canImport(PythonKit)
        do {
            let sys = try Python.attemptImport("sys")
            let io = try Python.attemptImport("io")

            if sys.stdin == Python.None || Bool(Python.hasattr(sys.stdin, "read")) != true {
                let stdinObj = io.open(0, mode: "r", encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdin = stdinObj
                sys.__stdin__ = stdinObj
            }
            if sys.stdout == Python.None || Bool(Python.hasattr(sys.stdout, "write")) != true {
                let stdoutObj = io.open(1, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdout = stdoutObj
                sys.__stdout__ = stdoutObj
            }
            if sys.stderr == Python.None || Bool(Python.hasattr(sys.stderr, "write")) != true {
                let stderrObj = io.open(2, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stderr = stderrObj
                sys.__stderr__ = stderrObj
            }
        } catch {
            fputs("Warning: Could not configure Python standard streams: \(error)\n", stderr)
        }
        #endif
    }

    /// Resolves candidate standard library and site-packages paths for sys.path configuration.
    public static func getPythonLibAndSitePackagesPaths() -> (libPaths: [String], sitePackagesPaths: [String]) {
        let bundleURL = Bundle.main.bundleURL
        let isXPC = bundleURL.pathExtension == "xpc"
        let parentAppContents = isXPC ? bundleURL.deletingLastPathComponent().deletingLastPathComponent() : bundleURL.appendingPathComponent("Contents")
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDir = execURL.deletingLastPathComponent()

        var libPaths: [String] = []
        var spPaths: [String] = []

        let libCandidates = [
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            parentAppContents.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/Current/lib/python3.13"),
            parentAppContents.appendingPathComponent("Resources/python_3_13/Python.framework/Versions/3.13/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
        ]

        let spCandidates = [
            execURL.appendingPathComponent("../../Resources/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../../../Resources/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../../Resources/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Resources/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../../Resources/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../../../Resources/site-packages").standardizedFileURL,
            parentAppContents.appendingPathComponent("Resources/site-packages"),
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../../../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages").standardizedFileURL,
            parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            parentAppContents.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Resources/site-packages"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
        ]

        if let resURL = Bundle.main.resourceURL {
            let sp = resURL.appendingPathComponent("site-packages")
            if FileManager.default.fileExists(atPath: sp.path) {
                spPaths.append(sp.path)
            }
        }

        for c in libCandidates {
            if FileManager.default.fileExists(atPath: c.path) && !libPaths.contains(c.path) {
                libPaths.append(c.path)
            }
        }

        for c in spCandidates {
            if FileManager.default.fileExists(atPath: c.path) && !spPaths.contains(c.path) {
                spPaths.append(c.path)
            }
        }

        return (libPaths, spPaths)
    }

    /// Diagnoses candidate Python library paths using dynamic linker `dlopen` dry run and `dlerror`.
    public static func diagnosePythonLibraryLoading(candidatePaths: [String]) -> (selectedPath: String?, diagnostics: [String]) {
        var logs: [String] = []
        var selectedPath: String? = nil

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else {
                logs.append("Candidate '\(path)': NOT FOUND on disk")
                continue
            }

            // Attempt dry-run dlopen to inspect dyld link status
            let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if let handle = handle {
                logs.append("Candidate '\(path)': OK (dlopen succeeded)")
                if selectedPath == nil {
                    selectedPath = path
                }
                dlclose(handle)
            } else {
                let errStr: String
                if let errCStr = dlerror() {
                    errStr = String(cString: errCStr)
                } else {
                    errStr = "Unknown dlopen failure"
                }
                logs.append("Candidate '\(path)': FAILED dyld load -> \(errStr)")
            }
        }

        return (selectedPath, logs)
    }

    /// Diagnoses candidate Postgres libpq library paths using dynamic linker `dlopen` dry run and `dlerror`.
    public static func diagnosePostgresLibraryLoading(candidatePaths: [String]) -> (selectedPath: String?, diagnostics: [String]) {
        var logs: [String] = []
        var selectedPath: String? = nil

        for path in candidatePaths {
            guard FileManager.default.fileExists(atPath: path) else {
                logs.append("Postgres candidate '\(path)': NOT FOUND on disk")
                continue
            }

            // Attempt dry-run dlopen to inspect dyld link status
            let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if let handle = handle {
                logs.append("Postgres candidate '\(path)': OK (dlopen succeeded)")
                if selectedPath == nil {
                    selectedPath = path
                }
                dlclose(handle)
            } else {
                let errStr: String
                if let errCStr = dlerror() {
                    errStr = String(cString: errCStr)
                } else {
                    errStr = "Unknown dlopen failure"
                }
                logs.append("Postgres candidate '\(path)': FAILED dyld load -> \(errStr)")
            }
        }

        return (selectedPath, logs)
    }

    // MARK: - Private Helpers

    private static func locateServiceBundle(bundleId: String, executableName: String) -> (bundleURL: URL?, executableURL: URL?) {
        var searchRoots: [URL] = []

        if let mainBundle = Bundle.main.bundleURL as URL? {
            searchRoots.append(mainBundle.appendingPathComponent("Contents/XPCServices"))
            searchRoots.append(mainBundle.appendingPathComponent("XPCServices"))
            searchRoots.append(mainBundle.deletingLastPathComponent().appendingPathComponent("Contents/XPCServices"))
            searchRoots.append(mainBundle.deletingLastPathComponent().appendingPathComponent("XPCServices"))
        }

        let candidates = [
            "\(executableName).xpc",
            "\(bundleId).xpc"
        ]

        for root in searchRoots {
            for cand in candidates {
                let bundleURL = root.appendingPathComponent(cand)
                let execURL = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    return (bundleURL, execURL)
                }
            }
        }

        return (nil, nil)
    }

    private static func findRecentCrashReport(executableName: String, maxAge: TimeInterval) -> String? {
        let fileManager = FileManager.default
        var searchDirs: [URL] = []

        let home = fileManager.homeDirectoryForCurrentUser
        searchDirs.append(home.appendingPathComponent("Library/Logs/DiagnosticReports"))
        searchDirs.append(URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"))

        let now = Date()
        var candidateFiles: [(url: URL, mtime: Date)] = []

        for dir in searchDirs {
            guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for fileURL in files {
                let filename = fileURL.lastPathComponent
                if filename.contains(executableName) && (filename.hasSuffix(".ips") || filename.hasSuffix(".crash") || filename.hasSuffix(".diag")) {
                    if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let mtime = attrs[.modificationDate] as? Date {
                        if now.timeIntervalSince(mtime) <= maxAge {
                            candidateFiles.append((fileURL, mtime))
                        }
                    }
                }
            }
        }

        candidateFiles.sort { $0.mtime > $1.mtime }
        guard let mostRecent = candidateFiles.first else { return nil }

        if let content = try? String(contentsOf: mostRecent.url, encoding: .utf8) {
            return "File: \(mostRecent.url.lastPathComponent)\n\(content.prefix(2000))"
        }
        return "Recent crash file found: \(mostRecent.url.lastPathComponent)"
    }

    private static func extractDyldError(from crashReport: String?) -> String? {
        guard let report = crashReport else { return nil }

        let dyldIndicators = [
            "Termination Reason:    Namespace DYLD",
            "Termination Reason: DYLD",
            "Library not loaded:",
            "Symbol not found:",
            "referenced from:",
            "reason: image not found",
            "dyld: launch, loading dependent libraries",
            "dyld[",
        ]

        var relevantLines: [String] = []
        let lines = report.components(separatedBy: "\n")
        for line in lines {
            for ind in dyldIndicators {
                if line.contains(ind) {
                    relevantLines.append(line.trimmingCharacters(in: .whitespaces))
                    break
                }
            }
        }

        if !relevantLines.isEmpty {
            return relevantLines.joined(separator: " | ")
        }
        return nil
    }

    private static func readRecentLogs(forExecutableName executableName: String, bundleId: String) -> [String] {
        var entries: [String] = []
        if #available(macOS 12.0, *) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(timeIntervalSinceLatestBoot: 0)
                let allEntries = try store.getEntries(at: position)
                for entry in allEntries {
                    if let logEntry = entry as? OSLogEntryLog {
                        let text = logEntry.composedMessage
                        if text.contains(executableName) || text.contains(bundleId) || text.contains("dyld") || text.contains("CRITICAL") {
                            entries.append("[\(logEntry.subsystem)] \(text)")
                        }
                    }
                }
            } catch {
                // OSLogStore query might be restricted by sandbox
            }
        }
        return entries
    }

    private static func gatherEnvironmentDiagnostics() -> String {
        let env = ProcessInfo.processInfo.environment
        var items: [String] = []
        let trackedKeys = [
            "PYTHON_LIBRARY",
            "GARAGE_LIBPQ_PATH",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH",
            "DYLD_FALLBACK_FRAMEWORK_PATH",
            "PATH"
        ]

        for key in trackedKeys {
            if let val = env[key] {
                items.append("\(key)=\(val)")
            } else {
                items.append("\(key)=<unset>")
            }
        }
        return items.joined(separator: "\n")
    }
}
