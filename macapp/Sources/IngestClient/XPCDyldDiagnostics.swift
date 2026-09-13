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
