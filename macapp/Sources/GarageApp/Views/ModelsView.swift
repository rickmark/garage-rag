import SwiftUI
import AppKit
import LlamaClient
import ModelDownloadClient

struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    // MARK: - Configuration Mode & Form State
    enum ConfigMode: String, CaseIterable, Identifiable {
        case preset = "Preset Configuration"
        case custom = "Custom Configuration"

        var id: String { rawValue }
    }

    @State var configMode: ConfigMode = .preset
    @State var selectedPresetSlug: String = "bge-m3"
    @State var showAdvancedSettings: Bool = false

    @State var slug: String = "bge-m3"
    @State var modelName: String = "BGE-M3 (Embeddings)"
    @State var dims: String = "1024"
    @State var modelRef: String = "bge-m3"
    @State var provider: ModelProvider = .llamaXPC
    @State var makeDefault: Bool = false
    @State var busy: Bool = false
    @State var lmStudioToken: String = ""

    // Llama model loading configuration state
    @State var gpuLayers: Int = 33
    @State var cpuThreads: Int = 4
    @State var showUnloadConfirmation: Bool = false
    /// Alias the pending "Unload" confirmation applies to; `nil` unloads every model.
    @State var pendingUnloadAlias: String? = nil
    @State var settingFactsModelSlug: String? = nil

    // Testing Playground state
    @State var selectedTestModelSlug: String = ""
    @State var testPrompt: String = "Garage provides local retrieval-augmented generation for personal archives."
    @State var testEmbeddingDimensions: String = ""
    @State var searchText: String = ""
    @State var registeringPresetSlug: String? = nil

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
                // ===== Embedding Models =====
                sectionHeading(
                    "Text Embedding Models",
                    subtitle: "Vector models that index the corpus and power hybrid search. Each registered model gets its own embedding table."
                )

                // Section 1: Registered Models List & Status
                modelCatalogSection

                // Section 2: Available Models (Not Yet Registered)
                if !unregisteredPresetModels.isEmpty {
                    availableModelsSection
                }

                // Section 3: Model Configuration & Registration (Preset or Custom)
                configurationSection

                // Section 4: Non-Truncated Embedding Testing & Inspection
                embeddingInspectionSection

                // ===== Distillation Model =====
                sectionHeading(
                    "Distillation Model",
                    subtitle: "Generative model that distills documents into facts (Glean Facts) and answers rag_ask over MCP."
                )

                // Section 5: Fact Distillation Model
                distillationModelSection

                // Section 6: LM Studio API Token
                if provider == .lmStudio || appState.lmStudioTokenConfigured {
                    lmStudioTokenSection
                }

                // Section 7: Llama XPC Service Status
                llamaServiceSection

                // Section 8: Backfill / Enrichment Output
                backfillOutputSection

                // Section 9: Output / Feedback
                outputSection
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
            Text("This will free model memory in LlamaXPCService.")
        }
    }

    func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Section 1: Model Catalog & Registered Models List

    var modelCatalogSection: some View {
        GroupBox("Registered Models & Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unifiedModels.count) model\(unifiedModels.count == 1 ? "" : "s") registered in database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    TextField("Filter registered models…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)

                    if !modelDownload.downloadedModels.isEmpty {
                        Button("Verify") {
                            verifyAllDownloadedModels()
                        }
                        .controlSize(.small)
                        .disabled(modelDownload.isBusy)
                    }

                    Button("Embed All") {
                        backfillAllModels()
                    }
                    .disabled(appState.registeredModels.isEmpty || notReady || appState.backfill.isRunning)
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

                if filteredModels.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "cpu")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(unifiedModels.isEmpty ? "No registered models found." : "No matching registered models.")
                            .font(.headline)
                        Text("Select a preset or add a custom model configuration below to register a model in the database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredModels) { item in
                            modelCard(for: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    func modelCard(for item: UnifiedModelItem) -> some View {
        let isDownloaded = isModelFileDownloaded(item: item)
        let downloadedInfo = getDownloadedInfo(item: item)
        let isDownloading = isModelDownloading(item: item)
        let activeTask = getActiveDownloadTask(item: item)
        let isActiveInLlama = isModelActiveInLlama(item: item)
        let stats = appState.corpusStats.modelStats.first { $0.slug == item.slug }
        let totalChunks = appState.corpusStats.totalChunks
        let verification = downloadedInfo != nil ? modelDownload.verificationResult(for: downloadedInfo!.path) : nil
        let isVerifying = downloadedInfo != nil ? modelDownload.isVerifying(path: downloadedInfo!.path) : false

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        providerBadge(for: item.provider)

                        if item.isDefault {
                            StatusBadge("DEFAULT", tint: .green)
                        }

                        StatusBadge("REGISTERED", tint: .blue)

                        if isActiveInLlama {
                            StatusBadge("ACTIVE IN LLAMA XPC", tint: .purple)
                        }

                        if isDownloaded {
                            StatusBadge("DOWNLOADED (GGUF)", tint: .teal)

                            if isVerifying {
                                StatusBadge("VERIFYING SHA-256…", tint: .blue)
                            } else if let v = verification {
                                if v.isValid {
                                    StatusBadge("SHA-256 VERIFIED", tint: .green)
                                } else {
                                    StatusBadge("SHA-256 MISMATCH", tint: .red)
                                }
                            } else if item.effectiveSha256 != nil {
                                StatusBadge("SHA-256 UNVERIFIED", tint: .secondary)
                            }
                        } else if isDownloading {
                            StatusBadge("DOWNLOADING", tint: .orange)
                        }
                    }

                    Text(item.name)
                        .font(.headline)

                    HStack(spacing: 8) {
                        Text("Slug: \(item.slug)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if let dims = item.dims {
                            Text("•  \(dims) dims")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let ctx = item.contextSize {
                            Text("•  \(ctx) ctx")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if item.modelRef != item.slug {
                            Text("•  Ref: \(item.modelRef)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let dl = downloadedInfo {
                        Text("Local file: \(dl.filename) (\(dl.formattedSize))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    } else if let filename = item.effectiveFilename {
                        Text("GGUF target: \(filename)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    // A computed hash that matches the expected one replaces it rather than repeating it.
                    let verifiedMatch = verification.map { v in
                        v.isValid && v.computedSha256.caseInsensitiveCompare(item.effectiveSha256 ?? "") == .orderedSame
                    } ?? false

                    if let expectedSha = item.effectiveSha256, !verifiedMatch {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Expected SHA-256: \(expectedSha)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                modelDownload.copyToClipboard(text: expectedSha)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Copy expected SHA-256 hash")
                        }
                    }

                    if let v = verification {
                        HStack(spacing: 4) {
                            Image(systemName: v.isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(v.isValid ? .green : .red)
                            Text("\(verifiedMatch ? "Verified" : "Computed") SHA-256: \(v.computedSha256)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(v.isValid ? .green : .red)
                                .textSelection(.enabled)
                            Button {
                                modelDownload.copyToClipboard(text: v.computedSha256)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Copy computed SHA-256 hash")
                        }
                    }

                    if !isDownloaded, let task = activeTask, task.status == .downloading || task.status == .queued {
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: task.fractionCompleted)
                                .progressViewStyle(.linear)
                            HStack {
                                Text(task.formattedProgress)
                                Text("•  \(task.formattedSpeed)")
                                if !task.formattedETA.isEmpty {
                                    Text("•  ETA: \(task.formattedETA)")
                                }
                                Spacer()
                                Button("Cancel") {
                                    Task { await modelDownload.cancelDownload(taskId: task.id) }
                                }
                                .controlSize(.mini)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    // Download action to local Llama XPC (Default)
                    if item.provider == .llamaXPC && !isDownloaded && !isDownloading && item.effectiveDownloadURL != nil {
                        Button("Download to Llama XPC") {
                            downloadModelToLlamaXPC(item: item)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(modelDownload.isBusy)
                    }

                    // Load Model into Llama XPC
                    if isDownloaded, let dl = downloadedInfo {
                        if isActiveInLlama {
                            Button("Unload") {
                                pendingUnloadAlias = item.slug
                                showUnloadConfirmation = true
                            }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(llama.isBusy)
                        } else {
                            Button("Load Model") {
                                loadDownloadedModel(item: item, dlInfo: dl)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(llama.isBusy)
                        }

                        // Verifying is started from the actions menu; show that it is running.
                        if isVerifying {
                            ProgressView().controlSize(.mini)
                                .help("Verifying the file's SHA-256 checksum")
                        }
                    }

                    // Backfill Embeddings button
                    Button("Embed") {
                        backfillModel(slug: item.slug)
                    }
                    .controlSize(.small)
                    .disabled(notReady || appState.backfill.isRunning)

                    // Context Menu for additional actions
                    Menu {
                        Button("Test Embeddings") {
                            selectForTesting(item: item)
                        }

                        Button("Use in Configuration Form") {
                            populateForm(from: item)
                        }

                        if let expectedSha = item.effectiveSha256 {
                            Button("Copy Expected SHA-256") {
                                modelDownload.copyToClipboard(text: expectedSha)
                            }
                        }

                        Button("Embed") {
                            backfillModel(slug: item.slug)
                        }
                        .disabled(notReady || appState.backfill.isRunning)

                        Button("Set as Default Model") {
                            run { try await $0.setDefaultModel(slug: item.slug).message }
                        }
                        .disabled(notReady)

                        Button("Drop from Database", role: .destructive) {
                            run { try await $0.dropModel(slug: item.slug).message }
                        }
                        .disabled(notReady)

                        if isDownloaded, let dl = downloadedInfo {
                            Divider()
                            Button("Verify") {
                                Task { await modelDownload.verifyModelFile(path: dl.path, expectedSha256: item.effectiveSha256) }
                            }
                            Button("Reveal in Finder") {
                                modelDownload.revealInFinder(path: dl.path)
                            }
                            Button("Delete Downloaded GGUF", role: .destructive) {
                                Task { await modelDownload.deleteDownloadedModel(dl) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Model actions")
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 20)
                }
            }

            // Embedding progress details for model
            let embeddedCount = stats?.embeddedCount ?? 0
            let remaining = max(0, totalChunks - embeddedCount)
            let progressFraction = totalChunks > 0 ? min(1.0, max(0.0, Double(embeddedCount) / Double(totalChunks))) : 0.0
            let percentText = totalChunks > 0 ? String(format: "%.1f%%", progressFraction * 100) : "0%"

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .foregroundStyle(.purple)
                        .font(.caption)
                    Text("Embedding Progress:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    if totalChunks == 0 {
                        Text("No document chunks in corpus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if remaining == 0 {
                        Text("\(embeddedCount) / \(totalChunks) chunks (\(percentText))")
                            .font(.caption.monospaced())
                        StatusBadge("100% EMBEDDED", tint: .green)
                    } else {
                        Text("\(embeddedCount) / \(totalChunks) chunks (\(percentText)) • \(remaining) remaining")
                            .font(.caption.monospaced())
                        StatusBadge("\(remaining) PENDING", tint: .orange)
                    }
                    Spacer()
                }

                if totalChunks > 0 && remaining > 0 {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Section 2: Available Models (Not Yet Registered)

    var availableModelsSection: some View {
        GroupBox("Available Models (Not Yet Registered)") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Presets from models.json that aren't registered yet. Register one to enable embedding and search with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(unregisteredPresetModels) { preset in
                        availablePresetCard(preset)
                    }
                }
            }
            .padding(8)
        }
    }

    func availablePresetCard(_ preset: ModelPresetEntry) -> some View {
        let isRegistering = registeringPresetSlug == preset.slug

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.subheadline.bold())
                    if preset.featured {
                        StatusBadge("FEATURED", tint: .green)
                    }
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
                registerPreset(preset)
            } label: {
                if isRegistering {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Register")
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(registeringPresetSlug != nil || notReady)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func registerPreset(_ preset: ModelPresetEntry) {
        registeringPresetSlug = preset.slug
        Task {
            await appState.registerModel(preset: preset)
            await appState.fetchRegisteredModels()
            registeringPresetSlug = nil
        }
    }

    // MARK: - Section 3: Model Configuration & Registration

    var configurationSection: some View {
        GroupBox("Model Configuration & Registration") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Configuration Mode", selection: $configMode) {
                    ForEach(ConfigMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if configMode == .preset {
                    Picker("Preset Model", selection: $selectedPresetSlug) {
                        ForEach(unregisteredPresetModels) { preset in
                            Text(preset.featured ? "★ \(preset.name)" : preset.name).tag(preset.slug)
                        }
                    }
                    .onChange(of: selectedPresetSlug) { _, newSlug in
                        if let preset = appState.presetModels.first(where: { $0.slug == newSlug }) {
                            applyPreset(preset)
                        }
                    }
                    .onChange(of: unregisteredPresetModels) { _, available in
                        guard !available.contains(where: { $0.slug == selectedPresetSlug }), let first = available.first else { return }
                        applyPreset(first)
                    }
                    .onAppear {
                        guard !unregisteredPresetModels.contains(where: { $0.slug == selectedPresetSlug }), let first = unregisteredPresetModels.first else { return }
                        applyPreset(first)
                    }

                    if !showAdvancedSettings {
                        HStack(spacing: 12) {
                            Label(provider.displayName, systemImage: "cpu")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !dims.isEmpty {
                                Label("\(dims) dims", systemImage: "square.stack.3d.down.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !modelRef.isEmpty && modelRef != slug {
                                Label(modelRef, systemImage: "tag")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)

                        if let currentPreset = appState.presetModels.first(where: { $0.slug == selectedPresetSlug }), let sha = currentPreset.sha256 {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundStyle(.blue)
                                    .font(.caption)
                                Text("Expected SHA-256:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(sha)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Button {
                                    modelDownload.copyToClipboard(text: sha)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .help("Copy SHA-256 hash")
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Toggle("Advanced Settings", isOn: $showAdvancedSettings)
                }

                if configMode == .custom || showAdvancedSettings {
                    LabeledContent("Model Name") {
                        TextField("Human-readable name", text: $modelName)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Slug") {
                        TextField("e.g. bge-m3", text: $slug)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Dimensions (optional)") {
                        TextField("e.g. 1024 (required for custom models)", text: $dims)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Model Ref (optional)") {
                        TextField("Provider-side name if different (e.g. BAAI/bge-m3)", text: $modelRef)
                            .textFieldStyle(.roundedBorder)
                    }

                    Picker("Provider", selection: $provider) {
                        ForEach(ModelProvider.allCases) { prov in
                            Text(prov.displayName).tag(prov)
                        }
                    }
                }

                Toggle("Make default model for search and embedding", isOn: $makeDefault)

                HStack {
                    Button("Register \(provider.displayName) Model") {
                        // Snapshot the form for the async operation.
                        let slugValue = slug.trimmingCharacters(in: .whitespacesAndNewlines)
                        let dimsText = dims.trimmingCharacters(in: .whitespacesAndNewlines)
                        let refValue = modelRef.trimmingCharacters(in: .whitespacesAndNewlines)
                        let providerValue = provider.cliValue
                        let defaultValue = makeDefault
                        run(triggersMaintenance: true) { grpc in
                            var dimsValue: Int?
                            if !dimsText.isEmpty {
                                guard let parsed = Int(dimsText), parsed > 0 else {
                                    throw GarageGRPCError.rpcFailed("Dimensions must be a positive whole number, not '\(dimsText)'.")
                                }
                                dimsValue = parsed
                            }
                            return try await grpc.registerModel(
                                slug: slugValue,
                                dims: dimsValue,
                                modelRef: refValue.isEmpty ? nil : refValue,
                                provider: providerValue,
                                makeDefault: defaultValue
                            ).message
                        }
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)
                    .buttonStyle(.borderedProminent)

                    Button("List Registered Models") {
                        run { try await $0.listModels().summary }
                    }
                    .disabled(notReady)

                    Button("Set Default") {
                        run { try await $0.setDefaultModel(slug: slug).message }
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)

                    Button("Drop", role: .destructive) {
                        run { try await $0.dropModel(slug: slug).message }
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)

                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 5: Distillation Model

    /// The `fact_distil` presets, wrapped so the download/load helpers written for
    /// embedding rows apply unchanged.
    var distillationModelItems: [UnifiedModelItem] {
        appState.factDistilPresets.map { UnifiedModelItem(preset: $0) }
    }

    var distillationModelSection: some View {
        GroupBox("Fact Distillation Model") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Current facts model:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(appState.factsModel)
                                .font(.caption.monospaced().bold())
                            Text("via \(appState.factsProvider)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if llama.isModelLoaded(alias: appState.factsModel) {
                                StatusBadge("LOADED", tint: .purple)
                            } else {
                                StatusBadge("NOT LOADED", tint: .orange)
                            }
                        }
                        Text("Stored in garage.json under facts.model / facts.provider. Load the model here before running enrich-facts or rag_ask.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()

                    Button("Glean Facts (All)") {
                        enrichAllFacts()
                    }
                    .disabled(notReady || appState.enrichFacts.isRunning)

                    if appState.enrichFacts.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }

                if distillationModelItems.isEmpty {
                    Text("No fact_distil presets found in models.json.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(distillationModelItems) { item in
                            distillationCard(for: item)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    func distillationCard(for item: UnifiedModelItem) -> some View {
        let isDownloaded = isModelFileDownloaded(item: item)
        let downloadedInfo = getDownloadedInfo(item: item)
        let isDownloading = isModelDownloading(item: item)
        let activeTask = getActiveDownloadTask(item: item)
        let isLoaded = llama.isModelLoaded(alias: item.slug)
        let isFactsModel = appState.factsModel == item.slug
        let isSettingFacts = settingFactsModelSlug == item.slug

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        providerBadge(for: item.provider)

                        if isFactsModel {
                            StatusBadge("ACTIVE FACTS MODEL", tint: .green)
                        }

                        if isLoaded {
                            StatusBadge("LOADED IN LLAMA XPC", tint: .purple)
                        }

                        if isDownloaded {
                            StatusBadge("DOWNLOADED (GGUF)", tint: .teal)
                        } else if isDownloading {
                            StatusBadge("DOWNLOADING", tint: .orange)
                        }
                    }

                    Text(item.name)
                        .font(.headline)

                    HStack(spacing: 8) {
                        Text("Slug: \(item.slug)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if let ctx = item.contextSize {
                            Text("•  \(ctx) ctx")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let description = item.presetEntry?.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let dl = downloadedInfo {
                        Text("Local file: \(dl.filename) (\(dl.formattedSize))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    } else if let filename = item.effectiveFilename {
                        Text("GGUF target: \(filename)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if !isDownloaded, let task = activeTask, task.status == .downloading || task.status == .queued {
                        VStack(alignment: .leading, spacing: 3) {
                            ProgressView(value: task.fractionCompleted)
                                .progressViewStyle(.linear)
                            HStack {
                                Text(task.formattedProgress)
                                Text("•  \(task.formattedSpeed)")
                                if !task.formattedETA.isEmpty {
                                    Text("•  ETA: \(task.formattedETA)")
                                }
                                Spacer()
                                Button("Cancel") {
                                    Task { await modelDownload.cancelDownload(taskId: task.id) }
                                }
                                .controlSize(.mini)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    if item.provider == .llamaXPC && !isDownloaded && !isDownloading && item.effectiveDownloadURL != nil {
                        Button("Download to Llama XPC") {
                            downloadModelToLlamaXPC(item: item)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(modelDownload.isBusy)
                    }

                    if isDownloaded, let dl = downloadedInfo {
                        if isLoaded {
                            Button("Unload") {
                                pendingUnloadAlias = item.slug
                                showUnloadConfirmation = true
                            }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(llama.isBusy)
                        } else {
                            Button("Load") {
                                loadDownloadedModel(item: item, dlInfo: dl)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(llama.isBusy)
                        }
                    }

                    Button {
                        useForFacts(item: item)
                    } label: {
                        if isSettingFacts {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(isFactsModel ? "In use for facts" : "Use for facts")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isFactsModel || settingFactsModelSlug != nil || notReady)
                    .help("Sets facts.model to \(item.slug) and facts.provider to \(item.provider.cliValue) in garage.json")

                    if isDownloaded, let dl = downloadedInfo {
                        Menu {
                            Button("Verify") {
                                Task { await modelDownload.verifyModelFile(path: dl.path, expectedSha256: item.effectiveSha256) }
                            }
                            Button("Reveal in Finder") {
                                modelDownload.revealInFinder(path: dl.path)
                            }
                            Button("Delete Downloaded GGUF", role: .destructive) {
                                Task { await modelDownload.deleteDownloadedModel(dl) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Model actions")
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 20)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func useForFacts(item: UnifiedModelItem) {
        settingFactsModelSlug = item.slug
        Task {
            await appState.setFactsModel(item.slug, provider: item.provider.cliValue)
            settingFactsModelSlug = nil
        }
    }

    // MARK: - Section 6: LM Studio Token Section

    var lmStudioTokenSection: some View {
        GroupBox("LM Studio API Token") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    appState.lmStudioTokenConfigured
                        ? "A token is stored in Keychain and will be passed to Garage commands."
                        : "Optional for local LM Studio. Required when its API server requires authentication."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                SecureField("Paste API token", text: $lmStudioToken)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(appState.lmStudioTokenConfigured ? "Replace token" : "Save token") {
                        if appState.saveLMStudioToken(lmStudioToken) {
                            lmStudioToken = ""
                        }
                    }
                    .disabled(lmStudioToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if appState.lmStudioTokenConfigured {
                        Button("Remove token", role: .destructive) {
                            appState.removeLMStudioToken()
                            lmStudioToken = ""
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 7: Llama Service Status Section

    var llamaServiceSection: some View {
        GroupBox("Llama XPC Service Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle()
                        .fill(llama.statusColor)
                        .frame(width: 10, height: 10)
                    Text(llama.statusMessage)
                        .fontWeight(.medium)
                    Spacer()
                    if llama.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Ping") {
                        Task { await llama.ping() }
                    }
                    .disabled(llama.isBusy)
                    Button("Refresh") {
                        Task { await llama.refreshStatus() }
                    }
                    .disabled(llama.isBusy)
                }

                if let health = llama.health {
                    LabeledContent("Health Status", value: health.status)
                    if let idle = health.slotsIdle, let proc = health.slotsProcessing {
                        LabeledContent("Slots State", value: "\(idle) idle, \(proc) processing")
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 8: Backfill / Enrichment Output Section

    var backfillOutputSection: some View {
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
                GroupBox("Fact Enrichment Output") {
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

    // MARK: - Section 9: Output Section

    var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if llama.lastError != nil || llama.lastSuccess != nil || llama.testOutput != nil {
                GroupBox("Llama Output") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let err = llama.lastError {
                            Text("Error: \(err)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                        }
                        if let ok = llama.lastSuccess {
                            Text("Success: \(ok)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                        }
                        if let out = llama.testOutput {
                            Text("Output:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(out)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Badges & Helpers

    func providerBadge(for prov: ModelProvider) -> some View {
        switch prov {
        case .llamaXPC:
            return StatusBadge("LLAMA XPC", tint: .purple)
        case .ollama:
            return StatusBadge("OLLAMA", tint: .orange)
        case .lmStudio:
            return StatusBadge("LM STUDIO", tint: .teal)
        }
    }


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

    func verifyAllDownloadedModels() {
        Task {
            for dl in modelDownload.downloadedModels {
                let dlLast = URL(fileURLWithPath: dl.filename).lastPathComponent
                let expectedSha = unifiedModels.first(where: {
                    $0.effectiveFilename == dl.filename ||
                    $0.effectiveFilename == dlLast ||
                    ($0.effectiveFilename != nil && URL(fileURLWithPath: $0.effectiveFilename!).lastPathComponent == dlLast)
                })?.effectiveSha256
                    ?? appState.presetModels.first(where: {
                        $0.effectiveFilename == dl.filename ||
                        $0.effectiveFilename == dlLast ||
                        ($0.effectiveFilename != nil && URL(fileURLWithPath: $0.effectiveFilename!).lastPathComponent == dlLast)
                    })?.sha256
                    ?? ModelPresetCatalog.items.first(where: {
                        $0.filename == dl.filename ||
                        $0.filename == dlLast ||
                        URL(fileURLWithPath: $0.filename).lastPathComponent == dlLast
                    })?.sha256
                await modelDownload.verifyModelFile(path: dl.path, expectedSha256: expectedSha)
            }
        }
    }

    func loadDownloadedModel(item: UnifiedModelItem, dlInfo: DownloadedModelInfo?) {
        guard let dl = dlInfo ?? getDownloadedInfo(item: item) else { return }
        Task {
            await llama.loadModel(
                path: dl.path,
                alias: item.slug,
                config: [
                    "n_ctx": item.contextSize ?? 8192,
                    "n_gpu_layers": gpuLayers,
                    "threads": cpuThreads
                ]
            )
        }
    }

    func selectForTesting(item: UnifiedModelItem) {
        selectedTestModelSlug = item.slug
        if let dimsVal = item.dims {
            testEmbeddingDimensions = "\(dimsVal)"
        }
    }

    func applyPreset(_ preset: ModelPresetEntry) {
        selectedPresetSlug = preset.slug
        slug = preset.slug
        modelName = preset.name
        dims = preset.effectiveDims > 0 ? "\(preset.effectiveDims)" : ""
        modelRef = preset.modelRef ?? preset.slug
        provider = ModelProvider.from(string: preset.provider)
    }

    func populateForm(from item: UnifiedModelItem) {
        slug = item.slug
        modelName = item.name
        dims = item.dims.map(String.init) ?? ""
        modelRef = item.modelRef
        provider = item.provider
        if let preset = item.presetEntry {
            configMode = .preset
            selectedPresetSlug = preset.slug
        } else {
            configMode = .custom
        }
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
