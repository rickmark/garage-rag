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
    @State private var expandedServiceIds: Set<String> = []
    @State private var isGrpcExpanded: Bool = false
    @State private var grpcTestResult: (isSuccess: Bool, summary: String, details: String, durationMs: Double)? = nil
    @State private var isTestingGrpc: Bool = false
    @State private var copiedServiceId: String? = nil
    @State private var quickAddingModelSlug: String? = nil
    @State private var quickAddingSourceSlug: String? = nil
    @State private var isAddingAllSources: Bool = false
    @State private var isAddingAllModels: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                systemHealthHeader

                if showDefaultSourcesQuickAdd {
                    defaultSourcesQuickAddSection
                }

                if showFeaturedModelsQuickAdd {
                    featuredModelsQuickAddSection
                }

                corpusOverviewSection

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sortedStatusItems) { item in
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
                    .disabled(appState.isFetchingStats || appState.isIngesting || appState.isScanning)
                }
            }
            .padding(8)
        }
    }

    private var effectiveSourcesCount: Int {
        max(appState.registeredSources.count, appState.corpusStats.sourcesCount)
    }

    // MARK: - Default Sources Quick Add (Empty State)

    private var showDefaultSourcesQuickAdd: Bool {
        appState.postgres.status == .running && appState.registeredSources.isEmpty
    }

    private var defaultSourcesQuickAddSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("No sources are configured yet. Add one of these common locations to start indexing, or configure a custom source on the Sources page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 10) {
                    ForEach(SourcePreset.quickAdd) { preset in
                        quickSourceCard(for: preset)
                    }
                }

                Button {
                    selection = .sources
                } label: {
                    HStack(spacing: 4) {
                        Text("Configure Custom Source")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(8)
        } label: {
            HStack {
                Text("Get Started: Add a Source")
                Spacer()
                Button {
                    addAllQuickSources()
                } label: {
                    if isAddingAllSources {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add All")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(quickAddingSourceSlug != nil || isAddingAllSources || SourcePreset.quickAdd.isEmpty)
            }
        }
    }

    private func quickSourceCard(for preset: SourcePreset) -> some View {
        let isAdding = quickAddingSourceSlug == preset.id

        return VStack(alignment: .leading, spacing: 6) {
            Text(preset.title)
                .font(.subheadline.bold())
            Text(preset.spec.root)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Button {
                addQuickSource(preset)
            } label: {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Add")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(quickAddingSourceSlug != nil)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func addQuickSource(_ preset: SourcePreset) {
        quickAddingSourceSlug = preset.id
        Task {
            await appState.addSource(preset.spec)
            await appState.fetchRegisteredSources()
            quickAddingSourceSlug = nil
        }
    }

    private func addAllQuickSources() {
        isAddingAllSources = true
        let presets = SourcePreset.quickAdd
        Task {
            for preset in presets {
                quickAddingSourceSlug = preset.id
                await appState.addSource(preset.spec)
            }
            await appState.fetchRegisteredSources()
            quickAddingSourceSlug = nil
            isAddingAllSources = false
        }
    }

    // MARK: - Featured Models Quick Add (Empty State)

    private var featuredModelPresets: [ModelPresetEntry] {
        appState.presetModels.filter { $0.featured }
    }

    private var showFeaturedModelsQuickAdd: Bool {
        appState.postgres.status == .running && appState.registeredModels.isEmpty && !featuredModelPresets.isEmpty
    }

    private var featuredModelsQuickAddSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("No embedding models are registered yet. Add one of these recommended models to enable chunk embedding and search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(featuredModelPresets) { preset in
                        featuredModelCard(for: preset)
                    }
                }

                Button {
                    selection = .models
                } label: {
                    HStack(spacing: 4) {
                        Text("See All Models")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            .padding(8)
        } label: {
            HStack {
                Text("Get Started: Add a Model")
                Spacer()
                Button {
                    addAllFeaturedModels()
                } label: {
                    if isAddingAllModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add All")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(quickAddingModelSlug != nil || isAddingAllModels || featuredModelPresets.isEmpty)
            }
        }
    }

    private func featuredModelCard(for preset: ModelPresetEntry) -> some View {
        let isAdding = quickAddingModelSlug == preset.slug

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.subheadline.bold())
                    StatusBadge("FEATURED", tint: .green)
                    if preset.effectiveDims > 0 {
                        StatusBadge("\(preset.effectiveDims) DIMS", tint: .blue)
                    }
                }

                if let description = preset.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let useCases = preset.useCases, !useCases.isEmpty {
                    Text("Use cases: \(useCases.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                addFeaturedModel(preset)
            } label: {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Add Model")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(quickAddingModelSlug != nil)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func addFeaturedModel(_ preset: ModelPresetEntry) {
        quickAddingModelSlug = preset.slug
        Task {
            await appState.registerModel(preset: preset)
            await appState.fetchRegisteredModels()
            quickAddingModelSlug = nil
        }
    }

    private func addAllFeaturedModels() {
        isAddingAllModels = true
        let presets = featuredModelPresets
        Task {
            for preset in presets {
                quickAddingModelSlug = preset.slug
                await appState.registerModel(preset: preset)
            }
            await appState.fetchRegisteredModels()
            quickAddingModelSlug = nil
            isAddingAllModels = false
        }
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

    // MARK: - XPC Helper Services Section

    private var xpcServicesSection: some View {
        GroupBox("Services & Daemon Health Diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Real-time operational status and deep functional diagnostic testing beyond basic ping for all helpers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let lastRefreshed = appState.xpcServices.lastRefreshedAt {
                            Text("Last checked \(lastRefreshed, style: .time)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if appState.xpcServices.isRefreshingAll || appState.xpcServices.isTestingAll || isTestingGrpc {
                        ProgressView().controlSize(.small)
                    }

                    Button {
                        runAllFunctionalTests()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle.fill")
                            Text("Run All Tests")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(appState.xpcServices.isTestingAll || isTestingGrpc)

                    Button {
                        toggleExpandAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: allExpanded ? "chevron.up.circle" : "chevron.down.circle")
                            Text(allExpanded ? "Collapse All" : "Expand All")
                        }
                    }
                    .controlSize(.small)

                    Button {
                        Task {
                            await appState.xpcServices.refreshAll()
                            await appState.grpc.refreshStatus()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh All")
                        }
                    }
                    .controlSize(.small)
                    .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)

                    Button {
                        Task { await appState.xpcServices.restartAll() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle")
                            Text("Restart All")
                        }
                    }
                    .controlSize(.small)
                    .disabled(appState.xpcServices.isRefreshingAll || appState.xpcServices.isRestartingAll)
                }

                Divider()

                VStack(spacing: 10) {
                    // gRPC Core Daemon Service Row
                    grpcServiceRow

                    // XPC Helper Services Rows
                    ForEach(appState.xpcServices.services) { service in
                        xpcServiceRow(for: service)
                    }
                }
            }
            .padding(8)
        }
    }

    private var allExpanded: Bool {
        let allIds = Set(appState.xpcServices.services.map { $0.id }).union(["grpc"])
        return allIds.isSubset(of: expandedServiceIds) && isGrpcExpanded
    }

    private func toggleExpandAll() {
        if allExpanded {
            expandedServiceIds.removeAll()
            isGrpcExpanded = false
        } else {
            expandedServiceIds = Set(appState.xpcServices.services.map { $0.id })
            isGrpcExpanded = true
        }
    }

    private func runAllFunctionalTests() {
        Task {
            isTestingGrpc = true
            let grpcResult = await appState.grpc.testServiceQuery()
            grpcTestResult = grpcResult
            isTestingGrpc = false
            await appState.xpcServices.runAllDiagnosticTests()
        }
    }

    // MARK: - gRPC Service Row with Expandable Diagnostics

    private var grpcServiceRow: some View {
        let isExpanded = isGrpcExpanded
        let isRunning = appState.grpc.status == .running

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isGrpcExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                // Status Icon
                Group {
                    switch appState.grpc.status {
                    case .running:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .starting, .stopping:
                        ProgressView().controlSize(.small)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .stopped:
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.title3)
                .frame(width: 24)

                // Service Metadata
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Garage gRPC Daemon")
                            .font(.subheadline.bold())

                        Text("\(appState.grpc.host):\(appState.grpc.port)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if isRunning {
                            StatusBadge("RUNNING", tint: .green)
                        } else if case .failed = appState.grpc.status {
                            StatusBadge("FAILED", tint: .red)
                        } else {
                            StatusBadge("STOPPED", tint: .orange)
                        }

                        if let res = grpcTestResult {
                            if res.isSuccess {
                                StatusBadge("TEST PASSED", tint: .green)
                            } else {
                                StatusBadge("TEST FAILED", tint: .red)
                            }
                        }
                    }

                    Text("Provides gRPC endpoints for document search, models registry, corpus statistics, and daemon control.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Actions
                HStack(spacing: 6) {
                    Button {
                        Task {
                            isTestingGrpc = true
                            grpcTestResult = await appState.grpc.testServiceQuery()
                            isTestingGrpc = false
                            if !isGrpcExpanded {
                                withAnimation {
                                    isGrpcExpanded = true
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isTestingGrpc {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Query Services")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isTestingGrpc)

                    Button(isExpanded ? "Hide Test" : "Expand Test") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isGrpcExpanded.toggle()
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }

            // Expanded Functional Diagnostics View
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Beyond-Ping Functional Test: gRPC Services Query")
                                    .font(.caption.bold())
                                StatusBadge("gRPC RPC", tint: .purple)
                            }
                            Text("Executes GetStatus, GetVersion, ListModels, ListSources, and GetStats to verify gRPC server subsystem integrity.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                isTestingGrpc = true
                                grpcTestResult = await appState.grpc.testServiceQuery()
                                isTestingGrpc = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTestingGrpc {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Run Query Test")
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(isTestingGrpc)
                    }

                    if let res = grpcTestResult {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: res.isSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                    Text(res.summary)
                                        .font(.caption.bold())
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                }

                                Spacer()

                                Button {
                                    NSPasteboard.general.copy(res.details)
                                    copiedServiceId = "grpc"
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        if copiedServiceId == "grpc" { copiedServiceId = nil }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedServiceId == "grpc" ? "checkmark" : "doc.on.doc")
                                        Text(copiedServiceId == "grpc" ? "Copied!" : "Copy Output")
                                    }
                                }
                                .controlSize(.small)
                            }

                            MonospaceOutputBox(res.details, maxHeight: 140)
                        }
                    }
                }
                .padding(8)
                .background(Color.purple.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - XPC Helper Service Row with Expandable Diagnostics

    private func xpcServiceRow(for service: XPCServiceInfo) -> some View {
        let isExpanded = expandedServiceIds.contains(service.id)
        let isTesting = appState.xpcServices.testingServiceIds.contains(service.id)
        let diagResult = appState.xpcServices.diagnosticResults[service.id]
        let statusReport = appState.xpcServices.statusReports[service.id]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedServiceIds.remove(service.id)
                        } else {
                            expandedServiceIds.insert(service.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)

                // Status Icon
                Group {
                    switch service.state {
                    case .running:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .checking, .restarting:
                        ProgressView().controlSize(.small)
                    case .unreachable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    case .unknown:
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3)
                .frame(width: 24)

                // Service Metadata
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(service.name)
                            .font(.subheadline.bold())

                        Text(service.bundleId)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        if let pid = service.pid {
                            StatusBadge("PID: \(pid)", tint: .blue)
                        }

                        if let latency = service.latencyMs {
                            StatusBadge(String(format: "%.1f ms", latency), tint: .green)
                        }

                        if let report = statusReport, !report.tests.isEmpty {
                            let passedCount = report.tests.filter { $0.status == .passed }.count
                            let hasFailures = !report.failedTests.isEmpty
                            StatusBadge("\(passedCount)/\(report.tests.count) tests passed", tint: hasFailures ? .red : .green)
                        }

                        if service.state == .restarting {
                            StatusBadge("RESTARTING", tint: .orange)
                        } else if service.state == .checking {
                            StatusBadge("CHECKING", tint: .blue)
                        } else if case .unreachable = service.state {
                            StatusBadge("UNREACHABLE", tint: .red)
                        }

                        if let res = diagResult {
                            if res.isSuccess {
                                StatusBadge("TEST PASSED", tint: .green)
                            } else {
                                StatusBadge("TEST FAILED", tint: .red)
                            }
                        }
                    }

                    Text(service.serviceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let err = service.errorMessage {
                        Text("Error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let resp = service.pingResponse, !resp.isEmpty {
                        Text("Ping reply: \(resp)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Actions
                HStack(spacing: 6) {
                    Button {
                        Task {
                            _ = await appState.xpcServices.runDiagnosticTest(for: service.id)
                            if !isExpanded {
                                withAnimation {
                                    _ = expandedServiceIds.insert(service.id)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Test")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(isTesting || service.isChecking)

                    Button("Ping") {
                        Task { await appState.xpcServices.refresh(serviceId: service.id) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(service.isChecking || appState.xpcServices.isRefreshingAll)

                    Button("Restart") {
                        Task { await appState.xpcServices.restart(serviceId: service.id) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(service.isRunning ? .orange : .blue)
                    .disabled(service.isChecking || appState.xpcServices.isRestartingAll)

                    Button(isExpanded ? "Hide Test" : "Expand Test") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isExpanded {
                                expandedServiceIds.remove(service.id)
                            } else {
                                expandedServiceIds.insert(service.id)
                            }
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }

            // Expanded Functional Test View
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    xpcServiceReportSection(for: service, report: statusReport)

                    Divider()

                    let testInfo = diagnosticTestInfo(for: service.id)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Beyond-Ping Functional Test: \(testInfo.name)")
                                    .font(.caption.bold())
                                StatusBadge("Beyond Ping", tint: .blue)
                            }
                            Text(testInfo.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            Task {
                                _ = await appState.xpcServices.runDiagnosticTest(for: service.id)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTesting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "play.circle")
                                }
                                Text("Run Functional Test")
                            }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(isTesting)
                    }

                    if let res = diagResult {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                HStack(spacing: 6) {
                                    Image(systemName: res.isSuccess ? "checkmark.seal.fill" : "xmark.seal.fill")
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                    Text(res.summary)
                                        .font(.caption.bold())
                                        .foregroundStyle(res.isSuccess ? .green : .red)
                                }

                                Spacer()

                                Text(String(format: "%.1f ms", res.durationMs))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)

                                Button {
                                    NSPasteboard.general.copy(res.details)
                                    copiedServiceId = service.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        if copiedServiceId == service.id { copiedServiceId = nil }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: copiedServiceId == service.id ? "checkmark" : "doc.on.doc")
                                        Text(copiedServiceId == service.id ? "Copied!" : "Copy Output")
                                    }
                                }
                                .controlSize(.small)
                            }

                            MonospaceOutputBox(res.details, maxHeight: 140)
                        }
                    }
                }
                .padding(8)
                .background(Color.blue.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - In-Service Status Report, Self Tests & Managed Service Actions

    private func xpcServiceReportSection(for service: XPCServiceInfo, report: GarageXPCStatusReport?) -> some View {
        let isTesting = appState.xpcServices.testingServiceIds.contains(service.id)
        let isRestarting = appState.xpcServices.restartingServiceIds.contains(service.id)
        let actionsDisabled = isTesting || isRestarting || service.isChecking

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text("In-Service Diagnostics")
                    .font(.caption.bold())

                if let report = report {
                    StatusBadge(report.lifecycle.uppercased(), tint: lifecycleColor(report.lifecycle))
                    StatusBadge("UP \(formatUptime(report.uptimeSeconds))", tint: .secondary)
                    if let lastRun = report.lastTestRun {
                        Text("Tests ran \(Date(timeIntervalSince1970: lastRun), style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isRestarting {
                    ProgressView().controlSize(.small)
                }

                Button {
                    Task { _ = await appState.xpcServices.runServiceSelfTests(serviceId: service.id) }
                } label: {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checklist")
                        }
                        Text("Run Tests")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(actionsDisabled)

                Button {
                    Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: true) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Restart Services")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(actionsDisabled)

                Button {
                    Task { _ = await appState.xpcServices.restartManagedServices(serviceId: service.id, graceful: false) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.circle")
                        Text("Force Restart")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(actionsDisabled)

                Button {
                    Task { await appState.xpcServices.restart(serviceId: service.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power.circle")
                        Text("Restart Process")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(actionsDisabled || appState.xpcServices.isRestartingAll)
            }

            if let report = report {
                xpcPythonStatusLine(report.python)

                if !report.services.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Managed Services")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        ForEach(report.services, id: \.name) { managed in
                            xpcManagedServiceRow(managed)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    let passedCount = report.tests.filter { $0.status == .passed }.count
                    HStack(spacing: 6) {
                        Text("Self Tests")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        if !report.tests.isEmpty {
                            Text("\(passedCount) of \(report.tests.count) passed")
                                .font(.caption2)
                                .foregroundStyle(report.allTestsPassed ? .green : .red)
                        }
                    }
                    if report.tests.isEmpty {
                        Text("No self tests have been reported yet. Use “Run Tests” to execute them.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(report.tests.enumerated()), id: \.offset) { _, test in
                            xpcSelfTestRow(test)
                        }
                    }
                }

                if !report.recentErrorLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recent Errors (\(report.recentErrorLines.count))")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                        MonospaceOutputBox(report.recentErrorLines.joined(separator: "\n"), maxHeight: 200)
                    }
                }

                if let crash = report.lastCrashReport, !crash.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                            Text("Crash Report")
                                .font(.caption2.bold())
                                .foregroundStyle(.red)
                        }
                        MonospaceOutputBox(crash, maxHeight: 200)
                    }
                }

                if let logPath = report.logFilePath {
                    Text("Log file: \(logPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else {
                Text("No status report received from this helper yet. Ping the service or run its tests to collect diagnostics.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func xpcPythonStatusLine(_ python: GarageXPCPythonStatus) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: python.error == nil ? "terminal" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(python.error == nil ? Color.secondary : Color.red)
            if let error = python.error, !error.isEmpty {
                Text("Python \(python.state): \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                Text(pythonSummaryLine(python))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func pythonSummaryLine(_ python: GarageXPCPythonStatus) -> String {
        let version = python.version?.split(separator: " ").first.map { String($0) } ?? python.state
        var line = "Python \(version)"
        if let home = python.home, !home.isEmpty { line += " · home: \(home)" }
        if let initMs = python.initializationMs { line += String(format: " · init %.0f ms", initMs) }
        return line
    }

    private func xpcManagedServiceRow(_ managed: GarageXPCManagedServiceStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(managedServiceColor(managed.state))
                .frame(width: 7, height: 7)
            Text(managed.name)
                .font(.caption2.bold())
            StatusBadge(managed.state.uppercased(), tint: managedServiceColor(managed.state))
            if managed.restartCount > 0 {
                Text("restarts: \(managed.restartCount)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
            if let detail = managed.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func xpcSelfTestRow(_ test: GarageXPCTestResult) -> some View {
        let (icon, color): (String, Color) = {
            switch test.status {
            case .passed: return ("checkmark.circle", .green)
            case .failed: return ("xmark.circle", .red)
            case .skipped: return ("minus.circle", .gray)
            }
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(test.name)
                    .font(.caption.bold())
                Text(String(format: "%.1f ms", test.durationMs))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(test.summary)
                    .font(.caption2)
                    .foregroundStyle(test.status == .failed ? .red : .secondary)
                    .lineLimit(2)
                Spacer()
            }

            if test.status == .failed {
                if let error = test.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !test.details.isEmpty {
                    MonospaceOutputBox(test.details, maxHeight: 160)
                }
            } else if !test.details.isEmpty {
                DisclosureGroup {
                    MonospaceOutputBox(test.details, maxHeight: 120)
                } label: {
                    Text("Details")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, 2)
    }


    private func lifecycleColor(_ lifecycle: String) -> Color {
        switch lifecycle.lowercased() {
        case "ready": return .green
        case "degraded": return .orange
        case "failed": return .red
        case "bootstrapping": return .blue
        default: return .secondary
        }
    }

    private func managedServiceColor(_ state: String) -> Color {
        switch state.lowercased() {
        case "running": return .green
        case "starting", "restarting", "stopping": return .blue
        case "failed": return .red
        case "stopped": return .orange
        default: return .secondary
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86400)d \((total % 86400) / 3600)h"
    }

    private func diagnosticTestInfo(for serviceId: String) -> (name: String, description: String) {
        switch serviceId {
        case "embed-xpc", "me.rickmark.garage-rag.embed-xpc":
            return (
                name: "Model Load & Vector Embeddings",
                description: "Loads the vector embedding module and computes float vector coordinates on a fixed sample text."
            )
        case "model-download-xpc", "me.rickmark.garage-rag.model-download-xpc":
            return (
                name: "Payload Download & SHA-256 Checksum",
                description: "Downloads fixed small test payload data and validates SHA-256 cryptographic hash integrity."
            )
        case "llama-xpc", "me.rickmark.garage-rag.llama-xpc":
            return (
                name: "Llama Tokenizer & Server Status",
                description: "Tests Llama inference service properties, model slots, and tokenizer on a fixed prompt."
            )
        case "ingest-xpc", "me.rickmark.garage-rag.ingest-xpc":
            return (
                name: "Document Ingest Pipeline & Python Runtime",
                description: "Inspects PythonKit dynamic library resolution, tests signal handlers, verifies document extractors and chunkers."
            )
        case "mcp-server-xpc", "me.rickmark.garage-rag.mcp-server-xpc":
            return (
                name: "Model Context Protocol (MCP) Tools",
                description: "Initializes MCP protocol connection and discovers registered tools and capabilities."
            )
        case "garage-xpc", "me.rickmark.garage-rag.xpc":
            return (
                name: "Garage Backend Core Coordination",
                description: "Tests Core XPC daemon coordination and backend lifecycle communication."
            )
        default:
            return (
                name: "Service Check",
                description: "Functional readiness verification."
            )
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
