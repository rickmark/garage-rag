import SwiftUI
import AppKit

@MainActor
struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: AppSection?

    init(selection: Binding<AppSection?> = .constant(.status)) {
        self._selection = selection
    }

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

    @State private var refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemHealthHeader

                corpusOverviewSection

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
        .onAppear {
            Task {
                await appState.scanSources()
            }
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await appState.fetchCorpusStats()
            }
        }
    }

    // MARK: - Corpus & Progress Overview

    private var corpusOverviewSection: some View {
        GroupBox("Corpus & Pipeline Overview") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    sourcesMetricCard
                    Divider()
                    ingestionMetricCard
                    Divider()
                    chunkEmbeddingMetricCard
                }
                .padding(.vertical, 4)

                if !appState.registeredSources.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source Ingest Breakdown")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(appState.registeredSources) { src in
                            HStack {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Text(src.slug)
                                    .font(.caption.bold())
                                Spacer()
                                if src.expectedElements > 0 {
                                    let uningested = max(0, src.expectedElements - src.documentCount)
                                    Text("\(uningested) uningested (\(src.documentCount) of \(src.expectedElements) docs)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("\(src.documentCount) doc\(src.documentCount == 1 ? "" : "s") ingested")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }

                HStack {
                    if let lastUpdated = appState.corpusStats.lastUpdated {
                        Text("Updated \(lastUpdated, style: .time)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        Task { await appState.scanSources() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                            Text("Refresh")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(appState.isFetchingStats)
                }
            }
            .padding(8)
        }
    }

    private var effectiveSourcesCount: Int {
        max(appState.registeredSources.count, appState.corpusStats.sourcesCount)
    }

    private var sourcesMetricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.gear")
                    .foregroundStyle(.blue)
                Text("Sources")
                    .font(.subheadline.bold())
            }

            Text("\(effectiveSourcesCount)")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            if effectiveSourcesCount == 0 {
                Text("No sources configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let totalDocs = appState.corpusStats.documentsCount
                Text("\(effectiveSourcesCount) source\(effectiveSourcesCount == 1 ? "" : "s") (\(totalDocs) doc\(totalDocs == 1 ? "" : "s") ingested)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                selection = .sources
            } label: {
                Text("Manage Sources")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ingestionMetricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.green)
                Text("Ingestion Status")
                    .font(.subheadline.bold())
                if appState.ingest.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            let stats = appState.corpusStats
            if appState.ingest.isRunning {
                Text("Ingesting…")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            } else {
                Text("\(stats.uningestedElements)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
            }

            ProgressView(value: stats.ingestionProgressFraction)
                .progressViewStyle(.linear)

            if stats.uningestedElements > 0 {
                let total = max(stats.totalExpectedElements, stats.totalSeenFiles)
                if total > 0 {
                    Text("\(stats.uningestedElements) not ingested (\(stats.documentsCount) of \(total) files indexed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(stats.uningestedElements) element(s) not ingested")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if stats.documentsCount > 0 {
                Text("All \(stats.documentsCount) doc\(stats.documentsCount == 1 ? "" : "s") ingested\(stats.documentsFailedCount > 0 ? " (\(stats.documentsFailedCount) failed)" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No documents indexed yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                selection = .sources
            } label: {
                Text("View Ingest")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chunkEmbeddingMetricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .foregroundStyle(.purple)
                Text("Chunk Embedding")
                    .font(.subheadline.bold())
                if appState.backfill.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            let stats = appState.corpusStats
            if appState.backfill.isRunning {
                Text("Embedding…")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            } else {
                Text("\(stats.unembeddedChunks)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
            }

            ProgressView(value: stats.embeddingProgressFraction)
                .progressViewStyle(.linear)

            if stats.unembeddedChunks > 0 {
                let modelCount = max(1, stats.modelStats.count)
                let totalEmbedded = stats.totalEmbeddedAcrossAllModels
                let totalReq = stats.totalRequiredEmbeddingsAcrossAllModels
                if totalReq > 0 {
                    Text("\(stats.unembeddedChunks) not embedded (\(totalEmbedded) of \(totalReq) across \(modelCount) model\(modelCount == 1 ? "" : "s"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(stats.unembeddedChunks) chunks not yet embedded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if stats.totalChunks > 0 {
                let modelCount = max(1, stats.modelStats.count)
                Text("All \(stats.totalChunks) chunks embedded across \(modelCount) model\(modelCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No chunks generated yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                selection = .models
            } label: {
                Text("View Models")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var statusItems: [PageStatusItem] {
        Self.statusItems(for: appState)
    }

    var sortedStatusItems: [PageStatusItem] {
        Self.sortedStatusItems(for: appState)
    }

    var databaseStatusItem: PageStatusItem {
        Self.databaseStatusItem(for: appState)
    }

    var mcpStatusItem: PageStatusItem {
        Self.mcpStatusItem(for: appState)
    }

    var sourcesStatusItem: PageStatusItem {
        Self.sourcesStatusItem(for: appState)
    }

    var modelsStatusItem: PageStatusItem {
        Self.modelsStatusItem(for: appState)
    }

    var searchStatusItem: PageStatusItem {
        Self.searchStatusItem(for: appState)
    }

    var logsStatusItem: PageStatusItem {
        Self.logsStatusItem(for: appState)
    }

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
        statusItems(for: appState).sorted { (lhs, rhs) -> Bool in
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
            details = "Register an embedding model to enable semantic retrieval."
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
