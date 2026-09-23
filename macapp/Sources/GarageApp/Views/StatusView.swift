import SwiftUI
import AppKit
import Combine
import PythonXPCService

@MainActor
struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: AppSection?

    init(selection: Binding<AppSection?> = .constant(.status)) {
        self._selection = selection
    }


    @State var refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State var expandedServiceIds: Set<String> = []
    @State var isGrpcExpanded: Bool = false
    @State var grpcTestResult: (isSuccess: Bool, summary: String, details: String, durationMs: Double)? = nil
    @State var isTestingGrpc: Bool = false
    @State var copiedServiceId: String? = nil
    @State var quickAddingModelSlug: String? = nil
    @State var quickAddingSourceSlug: String? = nil
    @State var isAddingAllSources: Bool = false
    @State var isAddingAllModels: Bool = false

    var body: some View {
        // Evaluate the six page checks once per render; the header and the cards share them.
        let items = PageStatus.statusItems(for: appState)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemHealthHeader(PageStatus.HealthSummary(items: items))

                if showDefaultSourcesQuickAdd {
                    defaultSourcesQuickAddSection
                }

                if showFeaturedModelsQuickAdd {
                    featuredModelsQuickAddSection
                }

                corpusOverviewSection

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(PageStatus.sorted(items)) { item in
                        pageStatusCard(for: item)
                    }
                }

                xpcServicesSection

                LastCommandOutputBox(text: appState.lastCommandOutput)
            }
            .padding(20)
        }
        .navigationTitle("Status")
        .onAppear {
            Task {
                await appState.fetchRegisteredSources()
                await appState.fetchCorpusStats()
                await appState.xpcServices.refreshAll()
                if appState.xpcServices.statusReports.isEmpty {
                    await appState.xpcServices.refreshAllStatusReports()
                }
            }
        }
        .onReceive(refreshTimer) { _ in
            Task {
                await appState.fetchCorpusStats()
                await appState.xpcServices.refreshAll()
            }
        }
    }

    // MARK: - Corpus & Progress Overview

    var corpusOverviewSection: some View {
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
                    .disabled(appState.isFetchingStats || appState.isIngesting || appState.isScanning)
                }
            }
            .padding(8)
        }
    }

    var effectiveSourcesCount: Int {
        max(appState.registeredSources.count, appState.corpusStats.sourcesCount)
    }

    var sourcesMetricCard: some View {
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

    var ingestionMetricCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.green)
                Text("Ingestion Status")
                    .font(.subheadline.bold())
                if appState.isIngesting {
                    ProgressView().controlSize(.small)
                }
            }

            let stats = appState.corpusStats
            if appState.ingestService.isRunning, let progress = appState.ingestService.latestProgress {
                HStack(alignment: .firstTextBaseline) {
                    Text("Ingesting…")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                    Spacer()
                    Text(appState.combinedIngestProgressPercent)
                        .font(.system(size: 16, weight: .bold).monospaced())
                        .foregroundStyle(.blue)
                }

                ProgressView(value: appState.combinedIngestProgressFraction)
                    .progressViewStyle(.linear)

                if let cur = progress.currentItem, !cur.isEmpty {
                    Text(cur)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(appState.combinedIngestStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("\(stats.uningestedElements)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

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
            }

            Spacer()

            HStack {
                Button {
                    selection = .sources
                } label: {
                    Text("View Ingest")
                        .font(.caption)
                }
                .buttonStyle(.link)

                Spacer()

                if appState.isIngesting {
                    Button(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest") {
                        Task { await appState.cancelIngest() }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(appState.ingestService.isCancelling)
                } else if appState.isScanning {
                    Button("Cancel Scan") {
                        appState.cancelScan()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var chunkEmbeddingMetricCard: some View {
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
            } else if stats.unembeddedChunks == 0 && stats.totalChunks > 0 {
                Text("Complete")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
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

    func systemHealthHeader(_ health: PageStatus.HealthSummary) -> some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: health.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(health.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(health.title)
                        .font(.headline)
                    Text(health.subtitle)
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

    func pageStatusCard(for item: PageStatusItem) -> some View {
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

    // MARK: - Severity Helpers

    func severityIcon(for severity: PageStatusSeverity) -> String {
        switch severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "arrow.clockwise.circle.fill"
        case .healthy: return "checkmark.circle.fill"
        }
    }

    func severityColor(for severity: PageStatusSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        case .healthy: return .green
        }
    }

    func linkButtonText(for item: PageStatusItem) -> String {
        switch item.severity {
        case .critical, .warning:
            return "Go to \(item.title)"
        case .info, .healthy:
            return "Open \(item.title)"
        }
    }
}
