import SwiftUI

// The Status page's health model, independent of the view: one PageStatusItem
// per app page, evaluated from AppState. Tests exercise it without a View.

enum PageStatusSeverity: Int, Comparable, Equatable {
    case critical = 0   // Failure / Error (Red)
    case warning = 1    // Attention needed / Degraded / Stopped (Orange/Yellow)
    case info = 2       // In progress / Transitioning (Blue)
    case healthy = 3    // OK / Running / Configured (Green)

    static func < (lhs: PageStatusSeverity, rhs: PageStatusSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct PageStatusItem: Identifiable, Equatable {
    let section: AppSection
    let title: String
    let severity: PageStatusSeverity
    let statusHeadline: String
    let statusDetails: String
    let quickAction: QuickAction?

    var id: String { section.id }

    static func == (lhs: PageStatusItem, rhs: PageStatusItem) -> Bool {
        lhs.section == rhs.section &&
        lhs.title == rhs.title &&
        lhs.severity == rhs.severity &&
        lhs.statusHeadline == rhs.statusHeadline &&
        lhs.statusDetails == rhs.statusDetails &&
        lhs.quickAction?.label == rhs.quickAction?.label
    }

    struct QuickAction {
        let label: String
        let action: () -> Void
    }
}

@MainActor
enum PageStatus {
    // MARK: - Computation & Sorting

    static func statusItems(for appState: AppState) -> [PageStatusItem] {
        [
            databaseStatusItem(for: appState),
            mcpStatusItem(for: appState),
            sourcesStatusItem(for: appState),
            modelsStatusItem(for: appState),
            searchStatusItem(for: appState),
            logsStatusItem(for: appState)
        ]
    }

    static func sortedStatusItems(for appState: AppState) -> [PageStatusItem] {
        sorted(statusItems(for: appState))
    }

    /// Critical first, then warnings, then the rest; ties in page order.
    static func sorted(_ items: [PageStatusItem]) -> [PageStatusItem] {
        items.sorted { (lhs, rhs) -> Bool in
            if lhs.severity != rhs.severity {
                return lhs.severity < rhs.severity // Failing / Critical at the top
            }
            return lhs.section.rawValue < rhs.section.rawValue
        }
    }

    // MARK: - Individual Page Status Evaluators

    static func databaseStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        switch appState.postgres.status {
        case .failed(let message):
            severity = .critical
            headline = "Database Failed"
            details = message
            quickAction = PageStatusItem.QuickAction(label: "Retry") {
                Task { await appState.startPostgres() }
            }
        case .stopped:
            severity = .warning
            headline = "Database Stopped"
            details = "PostgreSQL is stopped. Search, sources ingest, and MCP service require PostgreSQL."
            quickAction = PageStatusItem.QuickAction(label: "Start") {
                Task { await appState.startPostgres() }
            }
        case .starting:
            severity = .info
            headline = "Database Starting…"
            details = "PostgreSQL server is starting up."
            quickAction = nil
        case .stopping:
            severity = .info
            headline = "Database Stopping…"
            details = "PostgreSQL server is shutting down."
            quickAction = nil
        case .needsMigration:
            severity = .warning
            headline = "Database Pending Migrations"
            details = "PostgreSQL cluster is running on port \(appState.postgres.port), but has unapplied schema migrations."
            quickAction = PageStatusItem.QuickAction(label: "Apply Migrations") {
                Task {
                    await appState.applyMigrations()
                }
            }
        case .running:
            severity = .healthy
            headline = "Database Running"
            details = "PostgreSQL cluster active on port \(appState.postgres.port) (\(appState.postgres.databaseName))."
            quickAction = nil
        }

        return PageStatusItem(
            section: .database,
            title: "Database",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: quickAction
        )
    }

    static func mcpStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        switch appState.mcp.status {
        case .failed(let message):
            severity = .critical
            headline = "MCP Server \(appState.mcp.status.title)"
            details = message
            quickAction = PageStatusItem.QuickAction(label: "Retry") {
                Task { try? await appState.mcp.start() }
            }
        case .stopped:
            severity = .warning
            headline = "MCP Server \(appState.mcp.status.title)"
            details = appState.mcp.status.detail(endpoint: appState.mcp.endpoint)
            quickAction = appState.postgres.status == .running
                ? PageStatusItem.QuickAction(label: "Start") { Task { try? await appState.mcp.start() } }
                : nil
        case .starting:
            severity = .info
            headline = "MCP Server \(appState.mcp.status.title)"
            details = appState.mcp.status.detail(endpoint: appState.mcp.endpoint)
            quickAction = nil
        case .stopping:
            severity = .info
            headline = "MCP Server \(appState.mcp.status.title)"
            details = appState.mcp.status.detail(endpoint: appState.mcp.endpoint)
            quickAction = nil
        case .running:
            if let testRes = appState.mcp.lastTestResult {
                if testRes.isSuccess {
                    severity = .healthy
                    headline = "MCP Server Running"
                    let latencyStr = String(format: "%.1f ms", testRes.latencyMs)
                    details = "Active on \(appState.mcp.endpoint.absoluteString) (\(testRes.tools.count) tools verified, \(latencyStr))."
                    quickAction = PageStatusItem.QuickAction(label: "Test") {
                        Task { await appState.mcp.testServerConnection() }
                    }
                } else {
                    severity = .warning
                    headline = "MCP Diagnostics Failed"
                    details = testRes.errorMessage ?? "Test failed"
                    quickAction = PageStatusItem.QuickAction(label: "Retest") {
                        Task { await appState.mcp.testServerConnection() }
                    }
                }
            } else {
                severity = .healthy
                headline = "MCP Server Running"
                details = "Active and listening on \(appState.mcp.endpoint.absoluteString)."
                quickAction = PageStatusItem.QuickAction(label: "Test") {
                    Task { await appState.mcp.testServerConnection() }
                }
            }
        }

        return PageStatusItem(
            section: .mcp,
            title: "MCP Server",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: quickAction
        )
    }

    static func sourcesStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        switch appState.volumeAccess.status {
        case .accessDenied(let reason):
            severity = .critical
            headline = appState.volumeAccess.status.title
            details = "App Sandbox permissions prevent reading local document sources: \(reason). Select root volume to restore access."
            quickAction = PageStatusItem.QuickAction(label: "Select Root…") {
                appState.promptAndSelectRootVolume()
            }
        case .notConfigured:
            severity = .warning
            headline = appState.volumeAccess.status.title
            details = "Sandbox disk access must be granted before indexing local directories."
            quickAction = PageStatusItem.QuickAction(label: "Select Root…") {
                appState.promptAndSelectRootVolume()
            }
        case .staleBookmark(let url):
            severity = .warning
            headline = appState.volumeAccess.status.title
            details = "Saved bookmark for \(url.path) needs re-granting."
            quickAction = PageStatusItem.QuickAction(label: "Re-grant…") {
                appState.promptAndSelectRootVolume()
            }
        case .accessGranted:
            if let testResult = appState.volumeAccess.lastTestResult, !testResult.isAccessible {
                let inaccessibleTCC = testResult.sourcePathResults.filter { !$0.isAccessible && ($0.requiresTCCPermission || $0.tccCategory != nil) }
                if !inaccessibleTCC.isEmpty {
                    severity = .warning
                    let names = inaccessibleTCC.map { $0.tccCategory?.displayName ?? $0.slug }.joined(separator: ", ")
                    headline = "Permissions Required: \(names)"
                    details = testResult.message
                    if let first = inaccessibleTCC.first {
                        let labelName = first.slug.isEmpty ? (first.tccCategory?.displayName ?? "Access") : first.slug
                        quickAction = PageStatusItem.QuickAction(label: "Grant \(labelName)…") {
                            appState.promptAndSelectSourceDirectory(slug: first.slug, suggestedPath: first.rawPath)
                        }
                    } else {
                        quickAction = PageStatusItem.QuickAction(label: "Open Privacy Settings") {
                            appState.openPrivacySettings(for: .fullDiskAccess)
                        }
                    }
                } else {
                    severity = .warning
                    headline = "Source Path Access Issue"
                    details = testResult.message
                    quickAction = PageStatusItem.QuickAction(label: "Test Access") {
                        _ = appState.testVolumeAccess()
                    }
                }
            } else if appState.ingestService.isRunning {
                severity = .info
                let src = appState.ingestService.currentSource ?? "All Sources"
                let pct = appState.combinedIngestProgressPercent
                headline = "Ingesting \(src)\(pct.isEmpty ? "" : " (\(pct))")"
                details = appState.ingestService.latestProgress?.message ?? "Currently ingesting files into personal archive."
                quickAction = PageStatusItem.QuickAction(label: appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest") {
                    Task { await appState.cancelIngest() }
                }
            } else if appState.isScanning {
                severity = .info
                headline = "Scanning Sources"
                details = "Scanning configured sources to calculate element counts."
                quickAction = PageStatusItem.QuickAction(label: "Cancel Scan") {
                    appState.cancelScan()
                }
            } else if appState.registeredSources.isEmpty {
                severity = .warning
                headline = "No Sources Configured"
                details = "No sources registered for document indexing."
                quickAction = nil
            } else {
                severity = .healthy
                headline = "Sources Configured & Accessible"
                let totalDocs = appState.corpusStats.documentsCount
                let uningested = appState.corpusStats.uningestedElements
                if uningested > 0 {
                    details = "\(appState.registeredSources.count) source(s) active with \(uningested) uningested element(s) (\(totalDocs) ingested)."
                } else if appState.corpusStats.totalSeenFiles > 0 {
                    details = "\(appState.registeredSources.count) source(s) active with \(totalDocs) document\(totalDocs == 1 ? "" : "s") ingested (\(appState.corpusStats.totalIndexedFiles) indexed of \(appState.corpusStats.totalSeenFiles) seen files)."
                } else {
                    details = "\(appState.registeredSources.count) source(s) active with \(totalDocs) document\(totalDocs == 1 ? "" : "s") ingested."
                }
                quickAction = nil
            }
        }

        return PageStatusItem(
            section: .sources,
            title: "Sources & Ingest",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: quickAction
        )
    }

    static func modelsStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        let hasActiveDownloads = appState.modelDownload.activeDownloads.contains {
            $0.status == .downloading || $0.status == .queued
        }

        if let llamaError = appState.llama.lastError, !appState.llama.isConnected {
            severity = .critical
            headline = "Llama Service Error"
            details = llamaError
            quickAction = PageStatusItem.QuickAction(label: "Retry") {
                Task { await appState.llama.refreshStatus() }
            }
        } else if appState.postgres.status == .running && appState.registeredModels.isEmpty {
            severity = .warning
            headline = "No Models Registered"
            details = "Register a text embedding model to enable semantic retrieval."
            quickAction = nil
        } else if hasActiveDownloads {
            severity = .info
            headline = "Model Downloading"
            details = "Downloading model weights in background."
            quickAction = nil
        } else if appState.backfill.isRunning {
            severity = .info
            headline = "Embedding in Progress"
            details = "Embedder is processing document chunks."
            quickAction = nil
        } else if appState.llama.isConnected {
            severity = .healthy
            headline = "Models & Llama Ready"
            let unembedded = appState.corpusStats.unembeddedChunks
            if unembedded > 0 {
                details = "Llama service connected. \(appState.registeredModels.count) model(s) registered with \(unembedded) chunk(s) remaining to embed across models."
            } else {
                details = "Llama service connected. \(appState.registeredModels.count) model(s) registered (\(appState.presetModels.count) presets available)."
            }
            quickAction = nil
        } else {
            severity = .healthy
            headline = "Models Configured"
            let unembedded = appState.corpusStats.unembeddedChunks
            if unembedded > 0 {
                details = "\(appState.registeredModels.count) model(s) registered with \(unembedded) chunk(s) remaining to embed across models."
            } else {
                details = "\(appState.registeredModels.count) model(s) registered (\(appState.presetModels.count) presets available)."
            }
            quickAction = nil
        }

        return PageStatusItem(
            section: .models,
            title: "Models",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: quickAction
        )
    }

    static func searchStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String

        if appState.postgres.status != .running {
            severity = .warning
            headline = "Search Unavailable"
            details = "PostgreSQL must be running to execute hybrid or vector searches."
        } else {
            severity = .healthy
            headline = "Search Ready"
            details = "Ready for hybrid, vector, and full-text queries."
        }

        return PageStatusItem(
            section: .search,
            title: "Search",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: nil
        )
    }

    static func logsStatusItem(for appState: AppState) -> PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String

        // The app itself runs everything over gRPC; `garage-mcp` is what stdio MCP
        // clients (Claude Desktop / Code) spawn.
        if !FileManager.default.isExecutableFile(atPath: Paths.garageMCP.path) {
            severity = .warning
            headline = "garage-mcp Launcher Missing"
            details = "Not found at \(Paths.garageMCP.path); stdio MCP clients cannot start the server."
        } else {
            severity = .healthy
            headline = "Logs Active"
            details = "Capturing diagnostic logs across all services."
        }

        return PageStatusItem(
            section: .logs,
            title: "Logs",
            severity: severity,
            statusHeadline: headline,
            statusDetails: details,
            quickAction: nil
        )
    }

    // MARK: - Overall Health Summary

    /// The header's verdict, derived from one evaluation of the page checks.
    struct HealthSummary {
        let criticalCount: Int
        let warningCount: Int

        init(items: [PageStatusItem]) {
            criticalCount = items.filter { $0.severity == .critical }.count
            warningCount = items.filter { $0.severity == .warning }.count
        }

        var symbol: String {
            if criticalCount > 0 { return "exclamationmark.triangle.fill" }
            if warningCount > 0 { return "exclamationmark.circle.fill" }
            return "checkmark.seal.fill"
        }

        var color: Color {
            if criticalCount > 0 { return .red }
            if warningCount > 0 { return .orange }
            return .green
        }

        var title: String {
            if criticalCount > 0 {
                return "\(criticalCount) Critical Issue\(criticalCount == 1 ? "" : "s") Detected"
            }
            if warningCount > 0 {
                return "\(warningCount) Component\(warningCount == 1 ? "" : "s") Need Attention"
            }
            return "All Systems Operational"
        }

        var subtitle: String {
            if criticalCount > 0 || warningCount > 0 {
                return "Components requiring attention are prioritized at the top with direct links to resolve."
            }
            return "All database, MCP, ingest, and search components are configured and healthy."
        }
    }
}
