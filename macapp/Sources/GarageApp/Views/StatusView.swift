import SwiftUI
import AppKit

@MainActor
struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: AppSection?

    init(selection: Binding<AppSection?> = .constant(.status)) {
        self._selection = selection
    }

    enum PageStatusSeverity: Int, Comparable {
        case critical = 0   // Failure / Error (Red)
        case warning = 1    // Attention needed / Degraded / Stopped (Orange/Yellow)
        case info = 2       // In progress / Transitioning (Blue)
        case healthy = 3    // OK / Running / Configured (Green)

        static func < (lhs: PageStatusSeverity, rhs: PageStatusSeverity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    struct PageStatusItem: Identifiable {
        let section: AppSection
        let title: String
        let severity: PageStatusSeverity
        let statusHeadline: String
        let statusDetails: String
        let quickAction: QuickAction?

        var id: String { section.id }

        struct QuickAction {
            let label: String
            let action: () -> Void
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemHealthHeader

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sortedStatusItems) { item in
                        pageStatusCard(for: item)
                    }
                }

                if !appState.lastCommandOutput.isEmpty {
                    GroupBox("Last Command Output") {
                        ScrollView {
                            Text(appState.lastCommandOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Status")
    }

    // MARK: - System Health Header

    private var systemHealthHeader: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: overallHealthIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(overallHealthColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(overallHealthTitle)
                        .font(.headline)
                    Text(overallHealthSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.postgres.status != .running {
                    Button("Start All Services") {
                        Task { await appState.startPostgres() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.postgres.status == .starting)
                } else if appState.mcp.status != .running {
                    Button("Start MCP Server") {
                        Task { try? await appState.mcp.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.mcp.status == .starting)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Page Status Card

    private func pageStatusCard(for item: PageStatusItem) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    // Status Icon
                    Image(systemName: severityIcon(for: item.severity))
                        .font(.title3)
                        .foregroundStyle(severityColor(for: item.severity))
                        .frame(width: 24)

                    // Page Symbol and Title
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: item.section.symbol)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(item.title)
                                .font(.headline)
                        }

                        Text(item.statusHeadline)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(item.severity == .critical ? Color.red : Color.primary)
                    }

                    Spacer()

                    // Quick in-place action if available
                    if let quickAction = item.quickAction {
                        Button(quickAction.label) {
                            quickAction.action()
                        }
                        .controlSize(.small)
                    }

                    // Direct link to the individual page
                    Button {
                        selection = item.section
                    } label: {
                        HStack(spacing: 4) {
                            Text(linkButtonText(for: item))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if !item.statusDetails.isEmpty {
                    Text(item.statusDetails)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Page Status Computation & Sorting

    private var statusItems: [PageStatusItem] {
        [
            databaseStatusItem,
            mcpStatusItem,
            sourcesStatusItem,
            modelsStatusItem,
            searchStatusItem,
            logsStatusItem
        ]
    }

    private var sortedStatusItems: [PageStatusItem] {
        statusItems.sorted { (lhs, rhs) -> Bool in
            if lhs.severity != rhs.severity {
                return lhs.severity < rhs.severity // Failing / Critical at the top
            }
            return lhs.section.rawValue < rhs.section.rawValue
        }
    }

    // MARK: - Individual Page Status Evaluators

    private var databaseStatusItem: PageStatusItem {
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

    private var mcpStatusItem: PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        switch appState.mcp.status {
        case .failed(let message):
            severity = .critical
            headline = "MCP Server Failed"
            details = message
            quickAction = PageStatusItem.QuickAction(label: "Retry") {
                Task { try? await appState.mcp.start() }
            }
        case .stopped:
            severity = .warning
            headline = "MCP Server Stopped"
            details = "Loopback HTTP MCP server is stopped."
            quickAction = appState.postgres.status == .running
                ? PageStatusItem.QuickAction(label: "Start") { Task { try? await appState.mcp.start() } }
                : nil
        case .starting:
            severity = .info
            headline = "MCP Server Starting…"
            details = "Starting garage-mcp on \(appState.mcp.endpoint.absoluteString)…"
            quickAction = nil
        case .stopping:
            severity = .info
            headline = "MCP Server Stopping…"
            details = "Stopping garage-mcp service…"
            quickAction = nil
        case .running:
            severity = .healthy
            headline = "MCP Server Running"
            details = "Active and listening on \(appState.mcp.endpoint.absoluteString)."
            quickAction = nil
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

    private var sourcesStatusItem: PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String
        let quickAction: PageStatusItem.QuickAction?

        switch appState.volumeAccess.status {
        case .accessDenied(let reason):
            severity = .critical
            headline = "Disk Access Denied"
            details = "App Sandbox permissions prevent reading local document sources: \(reason). Select root volume to restore access."
            quickAction = PageStatusItem.QuickAction(label: "Select Root…") {
                appState.promptAndSelectRootVolume()
            }
        case .notConfigured:
            severity = .warning
            headline = "Disk Access Not Configured"
            details = "Sandbox disk access must be granted before indexing local directories."
            quickAction = PageStatusItem.QuickAction(label: "Select Root…") {
                appState.promptAndSelectRootVolume()
            }
        case .staleBookmark(let url):
            severity = .warning
            headline = "Disk Access Stale"
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
            } else if appState.ingest.isRunning {
                severity = .info
                headline = "Ingestion in Progress"
                details = "Currently ingesting files into personal archive."
                quickAction = nil
            } else if appState.registeredSources.isEmpty {
                severity = .warning
                headline = "No Sources Configured"
                details = "No sources registered for document indexing."
                quickAction = nil
            } else {
                severity = .healthy
                headline = "Sources Configured & Accessible"
                details = "\(appState.registeredSources.count) source(s) active with verified disk access."
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

    private var modelsStatusItem: PageStatusItem {
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
            details = "Register an embedding model to enable semantic retrieval."
            quickAction = nil
        } else if hasActiveDownloads {
            severity = .info
            headline = "Model Downloading"
            details = "Downloading model weights in background."
            quickAction = nil
        } else if appState.llama.isConnected {
            severity = .healthy
            headline = "Models & Llama Ready"
            details = "Llama service connected. \(appState.registeredModels.count) model(s) registered (\(appState.presetModels.count) presets available)."
            quickAction = nil
        } else {
            severity = .healthy
            headline = "Models Configured"
            details = "\(appState.registeredModels.count) model(s) registered (\(appState.presetModels.count) presets available)."
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

    private var searchStatusItem: PageStatusItem {
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

    private var logsStatusItem: PageStatusItem {
        let severity: PageStatusSeverity
        let headline: String
        let details: String

        if !appState.garage.cliAvailable {
            severity = .warning
            headline = "garage CLI Missing"
            details = "CLI binary not found at \(Paths.garageCLI.path)."
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

    // MARK: - Severity Helpers

    private func severityIcon(for severity: PageStatusSeverity) -> String {
        switch severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "arrow.clockwise.circle.fill"
        case .healthy: return "checkmark.circle.fill"
        }
    }

    private func severityColor(for severity: PageStatusSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        case .healthy: return .green
        }
    }

    private func linkButtonText(for item: PageStatusItem) -> String {
        switch item.severity {
        case .critical, .warning:
            return "Go to \(item.title)"
        case .info, .healthy:
            return "Open \(item.title)"
        }
    }

    // MARK: - Overall Health Summary

    private var criticalCount: Int {
        statusItems.filter { $0.severity == .critical }.count
    }

    private var warningCount: Int {
        statusItems.filter { $0.severity == .warning }.count
    }

    private var overallHealthIcon: String {
        if criticalCount > 0 {
            return "exclamationmark.triangle.fill"
        } else if warningCount > 0 {
            return "exclamationmark.circle.fill"
        } else {
            return "checkmark.seal.fill"
        }
    }

    private var overallHealthColor: Color {
        if criticalCount > 0 {
            return .red
        } else if warningCount > 0 {
            return .orange
        } else {
            return .green
        }
    }

    private var overallHealthTitle: String {
        if criticalCount > 0 {
            return "\(criticalCount) Critical Issue\(criticalCount == 1 ? "" : "s") Detected"
        } else if warningCount > 0 {
            return "\(warningCount) Component\(warningCount == 1 ? "" : "s") Need Attention"
        } else {
            return "All Systems Operational"
        }
    }

    private var overallHealthSubtitle: String {
        if criticalCount > 0 || warningCount > 0 {
            return "Components requiring attention are prioritized at the top with direct links to resolve."
        } else {
            return "All database, MCP, ingest, and search components are configured and healthy."
        }
    }
}
