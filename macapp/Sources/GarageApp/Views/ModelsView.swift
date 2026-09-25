import SwiftUI
import AppKit
import LlamaClient
import LlamaModelLoader
import ModelDownloadClient

/// The Models page: the embedding models the corpus is indexed with, the model that distills
/// facts, and the local providers that serve them.
///
/// Each model is one row that answers what a person comes here for: is it on disk, is it loaded,
/// is the corpus embedded with it. Files, hashes and table names sit behind a chevron on the row;
/// adding a model and testing one are folded away until asked for.
struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - State

    /// The custom-model form, shown under the presets when "Custom model…" is open.
    @State var showCustomForm: Bool = false
    @State var slug: String = ""
    @State var dims: String = ""
    @State var modelRef: String = ""
    @State var provider: ModelProvider = .llamaXPC
    @State var makeDefault: Bool = false
    @State var busy: Bool = false
    @State var lmStudioToken: String = ""

    /// Alias the pending "Unload" confirmation applies to; `nil` unloads every model.
    @State var showUnloadConfirmation: Bool = false
    @State var pendingUnloadAlias: String? = nil
    @State var settingFactsModelSlug: String? = nil
    @State var registeringPresetSlug: String? = nil
    @State var searchText: String = ""
    /// Rows whose details (file, hashes, table) are open.
    @State var expandedSlugs: Set<String> = []

    // Embedding test
    @State var showEmbeddingTest: Bool = false
    @State var selectedTestModelSlug: String = ""
    @State var testPrompt: String = "Garage provides local retrieval-augmented generation for personal archives."
    @State var testEmbeddingDimensions: String = ""

    var llama: LlamaService {
        appState.llama
    }

    var modelDownload: ModelDownloadService {
        appState.modelDownload
    }

    // MARK: - Model Providers

    public enum ModelProvider: String, CaseIterable, Identifiable, Codable {
        case llamaXPC = "Llama XPC"
        case ollama = "Ollama"
        case lmStudio = "LM Studio"

        public var id: Self { self }

        public var displayName: String { rawValue }

        public var cliValue: String {
            switch self {
            case .llamaXPC: "llama_xpc"
            case .ollama: "ollama"
            case .lmStudio: "lmstudio"
            }
        }

        public static func from(string: String?) -> ModelProvider {
            guard let str = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return .llamaXPC
            }
            if str.contains("ollama") { return .ollama }
            if str.contains("lmstudio") || str.contains("lm_studio") || str.contains("lm studio") { return .lmStudio }
            return .llamaXPC
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                embeddingModelsSection
                distillationSection
                FactPromptsSection()
                providersSection
                embeddingTestSection
                activitySection
            }
            .padding(20)
        }
        .navigationTitle("Models")
        .task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
            await modelDownload.refresh()
            if !llama.isConnected {
                await llama.refreshStatus()
            }
        }
        .alert(pendingUnloadAlias.map { "Unload '\($0)'?" } ?? "Unload all models?", isPresented: $showUnloadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unload", role: .destructive) {
                let alias = pendingUnloadAlias
                pendingUnloadAlias = nil
                Task {
                    if let alias = alias {
                        await llama.unloadModel(alias: alias)
                    } else {
                        await llama.unloadModel()
                    }
                }
            }
        } message: {
            Text("This frees the model's memory in Llama XPC. Embedding and fact distillation load it again when they need it.")
        }
    }

    // MARK: - Text embedding models

    var embeddingModelsSection: some View {
        GroupBox("Text Embedding Models") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(embeddingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()

                    if unifiedModels.count > 3 {
                        TextField("Filter", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                    }

                    Button("Embed All") {
                        backfillAllModels()
                    }
                    .disabled(appState.registeredModels.isEmpty || notReady || appState.backfill.isRunning)
                    .help("Embed every chunk that is missing a vector, under every registered model")
                    .accessibilityIdentifier("models.embedAll")

                    Button {
                        refreshAll()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                    .accessibilityIdentifier("models.refresh")
                    .disabled(busy || appState.isFetchingModels)
                }

                if unifiedModels.isEmpty {
                    emptyState(
                        symbol: "circle.hexagongrid",
                        title: "No embedding model yet",
                        detail: "Search needs at least one. Add a recommended model below; the first one becomes the default."
                    )
                } else if filteredModels.isEmpty {
                    emptyState(symbol: "magnifyingglass", title: "No model matches \"\(searchText)\"", detail: nil)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredModels) { item in
                            modelRow(role: .embedding, item: item)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                addModelSection
            }
            .padding(8)
        }
    }

    /// "2 models · 9,120 of 10,000 chunks embedded", or what is missing for that to be true.
    var embeddingSummary: String {
        let count = unifiedModels.count
        let stats = appState.corpusStats
        if count == 0 {
            return "Text embedding models turn each chunk into a vector for semantic search. Each keeps its own vector table; search uses the default one."
        }
        let models = "\(count) model\(count == 1 ? "" : "s")"
        if stats.totalChunks == 0 {
            return "\(models) · no chunks to embed until a source is ingested"
        }
        let required = stats.totalRequiredEmbeddingsAcrossAllModels
        let missing = stats.unembeddedChunks
        if missing == 0 {
            return "\(models) · every chunk embedded"
        }
        let done = max(0, required - missing)
        return "\(models) · \(done.formatted()) of \(required.formatted()) embeddings done"
    }

    func emptyState(symbol: String, title: String, detail: String?) -> some View {
        VStack(alignment: .center, spacing: 6) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Fact distillation

    /// The `fact_distil` presets, wrapped so the download/load helpers written for
    /// embedding rows apply unchanged.
    var distillationModelItems: [UnifiedModelItem] {
        appState.factDistilPresets.map { UnifiedModelItem(preset: $0) }
    }

    /// The facts model garage.json names, when it is not one of the presets on the page.
    var unlistedFactsModel: String? {
        let slug = appState.factsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, !appState.factDistilPresets.contains(where: { $0.slug == slug }) else { return nil }
        return slug
    }

    var distillationSection: some View {
        GroupBox("Fact Distillation Model") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text("A small instruction-tuned model that gleans atomic facts from each document and answers rag_ask over MCP. One model is in use at a time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()

                    if appState.enrichFacts.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Button("Glean Facts") {
                        enrichAllFacts()
                    }
                    .disabled(notReady || appState.enrichFacts.isRunning)
                    .help("Run every enabled prompt over every document that has no facts from it yet")
                }

                if let unlisted = unlistedFactsModel {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("garage.json names \(unlisted) via \(appState.factsProvider), which is not one of the presets below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if distillationModelItems.isEmpty {
                    emptyState(
                        symbol: "text.quote",
                        title: "No distillation presets",
                        detail: "models.json lists no fact_distil models. Facts and rag_ask stay off until one is configured."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(distillationModelItems) { item in
                            modelRow(role: .distillation, item: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    func useForFacts(item: UnifiedModelItem) {
        settingFactsModelSlug = item.slug
        Task {
            await appState.setFactsModel(item.slug, provider: item.provider.cliValue)
            settingFactsModelSlug = nil
        }
    }

    // MARK: - Providers

    /// LM Studio gets a row once something on the page uses it, or a token is stored.
    var showsLMStudio: Bool {
        appState.lmStudioTokenConfigured
            || provider == .lmStudio
            || unifiedModels.contains { $0.provider == .lmStudio }
            || ModelProvider.from(string: appState.factsProvider) == .lmStudio
    }

    var providersSection: some View {
        GroupBox("Providers") {
            VStack(alignment: .leading, spacing: 10) {
                llamaProviderRow
                if showsLMStudio {
                    Divider()
                    lmStudioProviderRow
                }
            }
            .padding(8)
        }
    }

    var llamaProviderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ModelSymbolCircle(symbol: "cpu", tint: llama.statusColor, isActive: llama.isConnected)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Llama XPC")
                        .font(.system(size: 13, weight: .medium))
                    Text(llamaDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if llama.isBusy {
                    ProgressView().controlSize(.small)
                }
                if !llama.models.isEmpty {
                    Button("Unload All") {
                        pendingUnloadAlias = nil
                        showUnloadConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(llama.isBusy)
                }
                Button("Refresh") {
                    Task { await llama.refreshStatus() }
                }
                .controlSize(.small)
                .disabled(llama.isBusy)
            }

            if let err = llama.lastError {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, 38)
            }
        }
    }

    /// "Running · 2 models loaded · 3 slots idle", from the service's own status line.
    var llamaDetail: String {
        var parts: [String] = [llama.statusMessage]
        if llama.isConnected {
            let loaded = llama.loadedModelIds
            if loaded.isEmpty {
                parts.append("no model loaded")
            } else {
                parts.append("loaded: \(loaded.joined(separator: ", "))")
            }
            if let health = llama.health, let idle = health.slotsIdle, let proc = health.slotsProcessing {
                parts.append("\(idle) slot\(idle == 1 ? "" : "s") idle, \(proc) processing")
            }
        }
        return parts.joined(separator: " · ")
    }

    var lmStudioProviderRow: some View {
        HStack(alignment: .top, spacing: 10) {
            ModelSymbolCircle(symbol: "key", tint: .teal, isActive: appState.lmStudioTokenConfigured)

            VStack(alignment: .leading, spacing: 2) {
                Text("LM Studio")
                    .font(.system(size: 13, weight: .medium))
                Text(
                    appState.lmStudioTokenConfigured
                        ? "API token stored in the Keychain and sent with every request."
                        : "No API token. Only needed when LM Studio's server requires authentication."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            SecureField("API token", text: $lmStudioToken)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button(appState.lmStudioTokenConfigured ? "Replace" : "Save") {
                if appState.saveLMStudioToken(lmStudioToken) {
                    lmStudioToken = ""
                }
            }
            .controlSize(.small)
            .disabled(lmStudioToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if appState.lmStudioTokenConfigured {
                Button("Remove", role: .destructive) {
                    appState.removeLMStudioToken()
                    lmStudioToken = ""
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Activity

    var activitySection: some View {
        Group {
            if !appState.backfill.logs.isEmpty {
                GroupBox("Embedding Output") {
                    LogTableView(
                        lines: appState.backfill.logs,
                        sourceName: "Embed",
                        onClear: { appState.backfill.clearLogs() }
                    )
                    .frame(minHeight: 180, maxHeight: 300)
                }
            }
            if !appState.enrichFacts.logs.isEmpty {
                GroupBox("Fact Distillation Output") {
                    LogTableView(
                        lines: appState.enrichFacts.logs,
                        sourceName: "Enrich Facts",
                        onClear: { appState.enrichFacts.clearLogs() }
                    )
                    .frame(minHeight: 180, maxHeight: 300)
                }
            }
        }
    }

    // MARK: - Helpers

    var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    func refreshAll() {
        Task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await appState.fetchCorpusStats()
            await modelDownload.refresh()
            await llama.refreshStatus()
        }
    }

    func toggleExpanded(_ slug: String) {
        if expandedSlugs.contains(slug) {
            expandedSlugs.remove(slug)
        } else {
            expandedSlugs.insert(slug)
        }
    }

    func isModelFileDownloaded(item: UnifiedModelItem) -> Bool {
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloaded(filename: filename)
        }
        return false
    }

    func getDownloadedInfo(item: UnifiedModelItem) -> DownloadedModelInfo? {
        if let filename = item.effectiveFilename {
            return modelDownload.downloadedModel(for: filename)
        }
        return nil
    }

    func isModelDownloading(item: UnifiedModelItem) -> Bool {
        if isModelFileDownloaded(item: item) {
            return false
        }
        if let url = item.effectiveDownloadURL {
            return modelDownload.isModelDownloading(url: url)
        }
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloading(url: filename)
        }
        return false
    }

    func getActiveDownloadTask(item: UnifiedModelItem) -> DownloadTaskInfo? {
        if isModelFileDownloaded(item: item) {
            return nil
        }
        return modelDownload.activeDownloads.first {
            ($0.status == .downloading || $0.status == .queued) &&
            ($0.modelId == item.slug ||
            $0.filename == item.effectiveFilename ||
            URL(fileURLWithPath: $0.filename).lastPathComponent == item.effectiveFilename ||
            (item.effectiveFilename != nil && URL(fileURLWithPath: item.effectiveFilename!).lastPathComponent == URL(fileURLWithPath: $0.filename).lastPathComponent) ||
            $0.url == item.effectiveDownloadURL)
        }
    }

    func isModelActiveInLlama(item: UnifiedModelItem) -> Bool {
        guard let activeId = llama.activeModelId, llama.health?.status != "no_model_loaded" else {
            return false
        }
        return activeId == item.slug ||
            activeId == item.effectiveFilename ||
            llama.models.contains(where: { $0.id == item.slug || $0.id == item.effectiveFilename })
    }

    func downloadModelToLlamaXPC(item: UnifiedModelItem) {
        guard let url = item.effectiveDownloadURL else { return }
        Task {
            await modelDownload.startDownload(
                url: url,
                filename: item.effectiveFilename,
                modelId: item.slug,
                sha256: item.effectiveSha256
            )
        }
    }

    func loadDownloadedModel(item: UnifiedModelItem, dlInfo: DownloadedModelInfo?) {
        guard let dl = dlInfo ?? getDownloadedInfo(item: item) else { return }
        // The same settings an on-demand load (LlamaModelLoader) uses, so the model behaves alike
        // whichever loaded it.
        let plan = LlamaModelLoadPlan(
            alias: item.slug,
            displayName: item.name,
            path: dl.path,
            contextSize: item.contextSize ?? LlamaModelLoadDefaults.contextSize,
            gpuLayers: item.catalogItem?.defaultGpuLayers ?? LlamaModelLoadDefaults.gpuLayers
        )
        Task {
            await llama.loadModel(path: plan.path, alias: plan.alias, config: plan.config)
        }
    }

    func selectForTesting(item: UnifiedModelItem) {
        selectedTestModelSlug = item.slug
        if let dimsVal = item.dims {
            testEmbeddingDimensions = "\(dimsVal)"
        }
        showEmbeddingTest = true
    }

    func run(
        triggersMaintenance: Bool = false,
        _ operation: @escaping @MainActor (GarageGRPCService) async throws -> String
    ) {
        busy = true
        Task {
            await appState.runOperation(triggersMaintenance: triggersMaintenance, operation)
            await appState.fetchRegisteredModels()
            busy = false
        }
    }

    func backfillModel(slug: String) {
        busy = true
        Task {
            await appState.runBackfill(model: slug)
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            busy = false
        }
    }

    func backfillAllModels() {
        busy = true
        Task {
            await appState.runBackfill()
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            busy = false
        }
    }

    func enrichAllFacts() {
        Task {
            await appState.runEnrichFacts()
        }
    }

    func copyVectorToClipboard(vector: [Float]) {
        if let data = try? JSONSerialization.data(withJSONObject: vector, options: []),
           let jsonStr = String(data: data, encoding: .utf8) {
            NSPasteboard.general.copy(jsonStr)
        }
    }

    func copyCSVToClipboard(vector: [Float]) {
        let formatted = vector.map { String(format: "%.8f", $0) }.joined(separator: ", ")
        NSPasteboard.general.copy(formatted)
    }
}

/// The tinted circle a model or provider row starts with, in the shape of the menu bar's
/// Control Center-style rows: filled in the row's color while the thing is live, faint otherwise.
struct ModelSymbolCircle: View {
    let symbol: String
    let tint: Color
    var isActive: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? AnyShapeStyle(tint) : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
