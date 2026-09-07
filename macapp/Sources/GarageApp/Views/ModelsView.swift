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

    @State private var configMode: ConfigMode = .preset
    @State private var selectedPresetSlug: String = "bge-m3"
    @State private var showAdvancedSettings: Bool = false

    @State private var slug: String = "bge-m3"
    @State private var modelName: String = "BGE-M3 (Embeddings)"
    @State private var dims: String = "1024"
    @State private var modelRef: String = "bge-m3"
    @State private var provider: ModelProvider = .llamaXPC
    @State private var makeDefault: Bool = false
    @State private var busy: Bool = false
    @State private var lmStudioToken: String = ""

    // Llama model linking & configuration state
    @State private var modelPath: String = ""
    @State private var modelAlias: String = "bge-m3"
    @State private var contextSize: Int = 8192
    @State private var gpuLayers: Int = 33
    @State private var cpuThreads: Int = 4
    @State private var showAdvancedConfig: Bool = false
    @State private var customConfigJson: String = "{}"
    @State private var showUnloadConfirmation: Bool = false

    // Backfill state
    @State private var backfillSelection: String = "*"
    @State private var customBackfillSlug: String = ""

    // Testing Playground state
    @State private var testPrompt: String = "Garage provides local retrieval-augmented generation for personal archives."
    @State private var testMaxTokens: Int = 64
    @State private var testEmbeddingDimensions: String = ""
    @State private var showCopiedAlert: Bool = false
    @State private var searchText: String = ""

    private var llama: LlamaService {
        appState.llama
    }

    private var modelDownload: ModelDownloadService {
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

    // MARK: - Unified Model Item
    struct UnifiedModelItem: Identifiable, Hashable {
        var id: String { slug }
        let name: String
        let slug: String
        let provider: ModelProvider
        let modelRef: String
        let dims: Int?
        let storedDims: Int?
        let contextSize: Int?
        let isDefault: Bool
        let isRegistered: Bool
        let downloadModelId: String?
        let downloadFile: String?
        let catalogItem: ModelCatalogItem?
        let registeredModel: RegisteredModel?
        let presetEntry: ModelPresetEntry?

        static func == (lhs: UnifiedModelItem, rhs: UnifiedModelItem) -> Bool {
            lhs.slug == rhs.slug &&
            lhs.isRegistered == rhs.isRegistered &&
            lhs.isDefault == rhs.isDefault &&
            lhs.dims == rhs.dims &&
            lhs.provider == rhs.provider
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(slug)
            hasher.combine(isRegistered)
            hasher.combine(isDefault)
        }

        var effectiveDownloadURL: String? {
            if let downloadModelId = downloadModelId, let downloadFile = downloadFile,
               !downloadModelId.isEmpty, !downloadFile.isEmpty {
                return "https://huggingface.co/\(downloadModelId)/resolve/main/\(downloadFile)"
            }
            return catalogItem?.downloadUrl
        }

        var effectiveFilename: String? {
            if let downloadFile = downloadFile, !downloadFile.isEmpty {
                return downloadFile
            }
            return catalogItem?.filename
        }
    }

    private var unifiedModels: [UnifiedModelItem] {
        var items: [UnifiedModelItem] = []

        // Only registered models are shown in the models list
        for reg in appState.registeredModels {
            let prov = ModelProvider.from(string: reg.provider)
            let preset = appState.presetModels.first { $0.slug == reg.slug || $0.modelId == reg.modelRef }
            let catItem = ModelPresetCatalog.item(forModelIdOrSlug: reg.slug) ?? (preset != nil ? ModelPresetCatalog.item(forModelIdOrSlug: preset!.slug) : nil)
            items.append(
                UnifiedModelItem(
                    name: preset?.name ?? reg.slug,
                    slug: reg.slug,
                    provider: prov,
                    modelRef: reg.modelRef,
                    dims: reg.dims > 0 ? reg.dims : preset?.effectiveDims,
                    storedDims: reg.storedDims > 0 ? reg.storedDims : nil,
                    contextSize: preset?.contextSize ?? 8192,
                    isDefault: reg.isDefault,
                    isRegistered: true,
                    downloadModelId: preset?.downloadModelId,
                    downloadFile: preset?.downloadFile,
                    catalogItem: catItem,
                    registeredModel: reg,
                    presetEntry: preset
                )
            )
        }

        return items.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var filteredModels: [UnifiedModelItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return unifiedModels
        }
        return unifiedModels.filter {
            $0.name.lowercased().contains(trimmed) ||
            $0.slug.lowercased().contains(trimmed) ||
            $0.provider.displayName.lowercased().contains(trimmed) ||
            $0.modelRef.lowercased().contains(trimmed)
        }
    }

    private var unlinkedRegisteredLlamaModels: [UnifiedModelItem] {
        unifiedModels.filter { $0.isRegistered && $0.provider == .llamaXPC && !isModelFileDownloaded(item: $0) }
    }

    var effectiveBackfillSlug: String {
        if backfillSelection == "custom" {
            return customBackfillSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return backfillSelection
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Registered Models List & Status
                modelCatalogSection

                // Section 2: Model Configuration & Registration (Preset or Custom)
                configurationSection

                // Section 3: Link & Load Llama GGUF Model (only shown for registered models without connected GGUF files)
                if !unlinkedRegisteredLlamaModels.isEmpty || !modelPath.isEmpty {
                    linkLlamaModelSection
                }

                // Section 4: Backfill Embeddings (Single Model or All)
                backfillSection

                // Section 5: Non-Truncated Embedding Testing & Inspection
                embeddingInspectionSection

                // Section 6: LM Studio API Token
                if provider == .lmStudio || appState.lmStudioTokenConfigured {
                    lmStudioTokenSection
                }

                // Section 7: Llama XPC Service Status & Verification Playground
                llamaServiceSection

                // Section 8: Output / Feedback
                outputSection
            }
            .padding(20)
        }
        .navigationTitle("Models")
        .task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await modelDownload.refresh()
            if !llama.isConnected {
                await llama.refreshStatus()
            }
        }
        .alert("Unload active model?", isPresented: $showUnloadConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unload", role: .destructive) {
                Task { await llama.unloadModel() }
            }
        } message: {
            Text("This will free model memory in LlamaXPCService.")
        }
    }

    // MARK: - Section 1: Model Catalog & Registered Models List

    private var modelCatalogSection: some View {
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

                    Button("Refresh") {
                        refreshAll()
                    }
                    .disabled(busy || appState.isFetchingModels)

                    Button("Backfill All Models") {
                        runBackfill(["backfill"])
                    }
                    .disabled(notReady || unifiedModels.isEmpty)
                    .buttonStyle(.borderedProminent)
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

    private func modelCard(for item: UnifiedModelItem) -> some View {
        let isDownloaded = isModelFileDownloaded(item: item)
        let downloadedInfo = getDownloadedInfo(item: item)
        let isDownloading = isModelDownloading(item: item)
        let activeTask = getActiveDownloadTask(item: item)
        let isActiveInLlama = isModelActiveInLlama(item: item)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.headline)

                        providerBadge(for: item.provider)

                        if item.isDefault {
                            badgeText("DEFAULT", bg: Color.green.opacity(0.18), fg: .green)
                        }

                        if item.isRegistered {
                            badgeText("REGISTERED", bg: Color.blue.opacity(0.15), fg: .blue)
                        } else {
                            badgeText("PRESET", bg: Color.orange.opacity(0.15), fg: .orange)
                        }

                        if isActiveInLlama {
                            badgeText("ACTIVE IN LLAMA XPC", bg: Color.purple.opacity(0.2), fg: .purple)
                        }

                        if isDownloaded {
                            badgeText("DOWNLOADED (GGUF)", bg: Color.teal.opacity(0.15), fg: .teal)
                        } else if isDownloading {
                            badgeText("DOWNLOADING", bg: Color.yellow.opacity(0.2), fg: .orange)
                        }
                    }

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

                    if let task = activeTask {
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

                    // Link action: ONLY for models which are registered, but to which there is no connected gguf file for llama xpc to load
                    if item.isRegistered && item.provider == .llamaXPC && !isDownloaded {
                        Button("Link GGUF…") {
                            linkModelFile(for: item)
                        }
                        .controlSize(.small)
                        .disabled(llama.isBusy)
                    }

                    // Load Model into Llama XPC
                    if isDownloaded {
                        if isActiveInLlama {
                            Button("Unload") {
                                showUnloadConfirmation = true
                            }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(llama.isBusy)
                        } else {
                            Button("Load Model") {
                                loadDownloadedModel(item: item, dlInfo: downloadedInfo)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(llama.isBusy)
                        }
                    }

                    // Backfill button
                    Button("Backfill") {
                        backfillSelection = item.slug
                        runBackfill(["backfill", "--model", item.slug])
                    }
                    .controlSize(.small)
                    .disabled(notReady)

                    // Test Embeddings button
                    Button("Test") {
                        selectForTesting(item: item)
                    }
                    .controlSize(.small)

                    // Context Menu for additional actions
                    Menu {
                        Button("Use in Configuration Form") {
                            populateForm(from: item)
                        }

                        if item.isRegistered && item.provider == .llamaXPC && !isDownloaded {
                            Button("Link Local GGUF File…") {
                                linkModelFile(for: item)
                            }
                        }

                        if !item.isRegistered {
                            Button("Register in Database") {
                                registerModel(item: item)
                            }
                            .disabled(notReady)
                        } else {
                            Button("Set as Default Model") {
                                run(["set-default-model", item.slug])
                            }
                            .disabled(notReady)

                            Button("Drop from Database", role: .destructive) {
                                run(["drop-model", item.slug, "--yes"])
                            }
                            .disabled(notReady)
                        }

                        if isDownloaded, let dl = downloadedInfo {
                            Divider()
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
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Section 2: Model Configuration & Registration

    private var configurationSection: some View {
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
                        ForEach(appState.presetModels) { preset in
                            Text(preset.name).tag(preset.slug)
                        }
                    }
                    .onChange(of: selectedPresetSlug) { _, newSlug in
                        if let preset = appState.presetModels.first(where: { $0.slug == newSlug }) {
                            applyPreset(preset)
                        }
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
                            .onChange(of: slug) { _, newSlug in
                                if modelAlias.isEmpty || modelAlias == slug {
                                    modelAlias = newSlug
                                }
                            }
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

                Toggle("Make default model for search and backfill", isOn: $makeDefault)

                HStack {
                    Button("Register \(provider.displayName) Model") {
                        var args = ["register-model", slug, "--provider", provider.cliValue]
                        if !dims.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            args += ["--dims", dims.trimmingCharacters(in: .whitespacesAndNewlines)]
                        }
                        if !modelRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            args += ["--model-ref", modelRef.trimmingCharacters(in: .whitespacesAndNewlines)]
                        }
                        if makeDefault {
                            args.append("--default")
                        }
                        run(args)
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)
                    .buttonStyle(.borderedProminent)

                    Button("List Registered Models (CLI)") {
                        run(["list-models"])
                    }
                    .disabled(notReady)

                    Button("Set Default") {
                        run(["set-default-model", slug])
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)

                    Button("Drop", role: .destructive) {
                        run(["drop-model", slug, "--yes"])
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

    // MARK: - Section 3: Link & Load Llama Model

    private var linkLlamaModelSection: some View {
        GroupBox("Link & Load Llama Model (GGUF)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link and load a local GGUF model into the Llama XPC service for a registered model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !unlinkedRegisteredLlamaModels.isEmpty {
                    Picker("Registered Target Model", selection: $modelAlias) {
                        ForEach(unlinkedRegisteredLlamaModels) { model in
                            Text("\(model.name) (\(model.slug))").tag(model.slug)
                        }
                    }
                    .onChange(of: modelAlias) { _, newAlias in
                        if let selected = unlinkedRegisteredLlamaModels.first(where: { $0.slug == newAlias }) {
                            contextSize = selected.contextSize ?? 8192
                        }
                    }
                }

                if let activeModelId = llama.activeModelId, llama.health?.status != "no_model_loaded" {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Loaded Model: \(activeModelId)")
                                .font(.headline)
                            if let first = llama.models.first {
                                Text("Owned by: \(first.ownedBy) • Created: \(formattedDate(first.created))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Unload Model") {
                            showUnloadConfirmation = true
                        }
                        .tint(.red)
                        .disabled(llama.isBusy)
                    }
                    Divider()
                }

                LabeledContent("Model File Path") {
                    HStack {
                        TextField("/path/to/model.gguf", text: $modelPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            chooseModelFile()
                        }
                    }
                }

                LabeledContent("Model Alias") {
                    TextField("alias (e.g. \(slug.isEmpty ? "bge-m3" : slug))", text: $modelAlias)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 20) {
                    LabeledContent("Context Size") {
                        Picker("", selection: $contextSize) {
                            Text("2048").tag(2048)
                            Text("4096").tag(4096)
                            Text("8192").tag(8192)
                            Text("16384").tag(16384)
                            Text("32768").tag(32768)
                        }
                        .frame(width: 100)
                    }

                    LabeledContent("GPU Layers") {
                        Stepper("\(gpuLayers)", value: $gpuLayers, in: 0...99)
                            .frame(width: 100)
                    }

                    LabeledContent("Threads") {
                        Stepper("\(cpuThreads)", value: $cpuThreads, in: 1...16)
                            .frame(width: 90)
                    }
                }

                Toggle("Advanced JSON Configuration", isOn: $showAdvancedConfig)

                if showAdvancedConfig {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom config passed to llama-server:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $customConfigJson)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 70)
                            .border(Color.secondary.opacity(0.3), width: 1)
                    }
                }

                HStack {
                    Button("Load Model into Llama XPC Service") {
                        loadCurrentModel()
                    }
                    .disabled(modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || llama.isBusy)
                    .buttonStyle(.borderedProminent)

                    if llama.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 4: Backfill Section

    private var backfillSection: some View {
        GroupBox("Backfill Embeddings") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Embeds chunks that a model has no vectors for yet. You can backfill any one of the models or all of them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Model to Backfill") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $backfillSelection) {
                            Text("All Registered Models (*)").tag("*")
                            ForEach(unifiedModels) { m in
                                Text("\(m.name) (\(m.slug))").tag(m.slug)
                            }
                            Text("Custom Model Slug…").tag("custom")
                        }
                        .labelsHidden()

                        if backfillSelection == "custom" {
                            TextField("Enter model slug", text: $customBackfillSlug)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                HStack {
                    Button("Backfill \(effectiveBackfillSlug == "*" ? "All Models" : effectiveBackfillSlug)") {
                        if effectiveBackfillSlug == "*" {
                            runBackfill(["backfill"])
                        } else {
                            runBackfill(["backfill", "--model", effectiveBackfillSlug])
                        }
                    }
                    .disabled(notReady || effectiveBackfillSlug.isEmpty)
                    .buttonStyle(.borderedProminent)

                    Button("Backfill All Models") {
                        backfillSelection = "*"
                        runBackfill(["backfill"])
                    }
                    .disabled(notReady)

                    if appState.backfill.isRunning {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 5: Embeddings Inspection & Testing (No Truncation)

    private var embeddingInspectionSection: some View {
        GroupBox("Embeddings Inspection & Testing (Full Vector)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test and inspect the complete embedding vector of any model without truncation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Input Text to Embed") {
                    TextEditor(text: $testPrompt)
                        .font(.system(.body, design: .default))
                        .frame(height: 60)
                        .border(Color.secondary.opacity(0.3), width: 1)
                }

                HStack {
                    LabeledContent("Target Dimensions (optional)") {
                        TextField("default", text: $testEmbeddingDimensions)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }

                    Spacer()

                    Button("Generate Embedding Vector") {
                        let parsedDims = Int(testEmbeddingDimensions.trimmingCharacters(in: .whitespacesAndNewlines))
                        Task {
                            await llama.testEmbedding(text: testPrompt, dimensions: parsedDims)
                        }
                    }
                    .disabled(llama.isBusy || llama.health?.status == "no_model_loaded" || testPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)

                    if llama.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }

                if let vector = llama.lastEmbeddingVector, let stats = EmbeddingVectorStats(vector: vector) {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Embedding Vector Details")
                                .font(.headline)
                            badgeText("\(stats.count) DIMENSIONS", bg: Color.green.opacity(0.18), fg: .green)
                            badgeText("NO TRUNCATION", bg: Color.blue.opacity(0.15), fg: .blue)
                            Spacer()

                            Button("Copy Full Vector (JSON)") {
                                copyVectorToClipboard(vector: vector)
                            }
                            .controlSize(.small)

                            Button("Copy Values (CSV)") {
                                copyCSVToClipboard(vector: vector)
                            }
                            .controlSize(.small)
                        }

                        // Statistical summary grid
                        HStack(spacing: 12) {
                            statBox(title: "Dimensions", value: "\(stats.count)")
                            statBox(title: "Min Value", value: String(format: "%.6f", stats.min))
                            statBox(title: "Max Value", value: String(format: "%.6f", stats.max))
                            statBox(title: "Mean", value: String(format: "%.6f", stats.mean))
                            statBox(title: "L2 Norm", value: String(format: "%.6f", stats.l2Norm))
                        }

                        Text("Complete Vector Elements [0 .. \(stats.count - 1)] (Full, Non-Truncated):")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        // Full non-truncated scrollable vector view
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(0..<vector.count, id: \.self) { idx in
                                    HStack(spacing: 8) {
                                        Text("[\(idx)]")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48, alignment: .trailing)
                                        Text(String(format: "%.8f", vector[idx]))
                                            .font(.system(.caption, design: .monospaced))
                                        Spacer()
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 180)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(8)
        }
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced().bold())
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Section 6: LM Studio Token Section

    private var lmStudioTokenSection: some View {
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

    // MARK: - Section 7: Llama Service & Playground Section

    private var llamaServiceSection: some View {
        GroupBox("Llama XPC Service Status & Completion Playground") {
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

                Divider()
                Text("Text Completion Verification")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                LabeledContent("Prompt") {
                    TextField("Enter test prompt…", text: $testPrompt)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    LabeledContent("Max Tokens") {
                        TextField("64", value: $testMaxTokens, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    Spacer()
                    Button("Generate Completion") {
                        Task {
                            await llama.testCompletion(prompt: testPrompt, maxTokens: testMaxTokens)
                        }
                    }
                    .disabled(llama.isBusy || llama.health?.status == "no_model_loaded" || testPrompt.isEmpty)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Section 8: Output Section

    private var outputSection: some View {
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

            if !appState.backfill.logs.isEmpty {
                GroupBox("Backfill output") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(appState.backfill.logs) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.stream == .stderr ? .red : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .padding(8)
                }
            }
        }
    }

    // MARK: - Badges & Helpers

    private func providerBadge(for prov: ModelProvider) -> some View {
        switch prov {
        case .llamaXPC:
            return badgeText("LLAMA XPC", bg: Color.purple.opacity(0.15), fg: .purple)
        case .ollama:
            return badgeText("OLLAMA", bg: Color.orange.opacity(0.15), fg: .orange)
        case .lmStudio:
            return badgeText("LM STUDIO", bg: Color.teal.opacity(0.15), fg: .teal)
        }
    }

    private func badgeText(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    private func refreshAll() {
        Task {
            appState.fetchPresetModels()
            await appState.fetchRegisteredModels()
            await modelDownload.refresh()
            await llama.refreshStatus()
        }
    }

    private func isModelFileDownloaded(item: UnifiedModelItem) -> Bool {
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloaded(filename: filename)
        }
        return false
    }

    private func getDownloadedInfo(item: UnifiedModelItem) -> DownloadedModelInfo? {
        if let filename = item.effectiveFilename {
            return modelDownload.downloadedModel(for: filename)
        }
        return nil
    }

    private func isModelDownloading(item: UnifiedModelItem) -> Bool {
        if let url = item.effectiveDownloadURL {
            return modelDownload.isModelDownloading(url: url)
        }
        if let filename = item.effectiveFilename {
            return modelDownload.isModelDownloading(url: filename)
        }
        return false
    }

    private func getActiveDownloadTask(item: UnifiedModelItem) -> DownloadTaskInfo? {
        modelDownload.activeDownloads.first {
            $0.modelId == item.slug ||
            $0.filename == item.effectiveFilename ||
            $0.url == item.effectiveDownloadURL
        }
    }

    private func isModelActiveInLlama(item: UnifiedModelItem) -> Bool {
        guard let activeId = llama.activeModelId, llama.health?.status != "no_model_loaded" else {
            return false
        }
        return activeId == item.slug ||
            activeId == item.effectiveFilename ||
            llama.models.contains(where: { $0.id == item.slug || $0.id == item.effectiveFilename })
    }

    private func downloadModelToLlamaXPC(item: UnifiedModelItem) {
        guard let url = item.effectiveDownloadURL else { return }
        Task {
            await modelDownload.startDownload(
                url: url,
                filename: item.effectiveFilename,
                modelId: item.slug
            )
        }
    }

    private func loadDownloadedModel(item: UnifiedModelItem, dlInfo: DownloadedModelInfo?) {
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

    private func selectForTesting(item: UnifiedModelItem) {
        if let dl = getDownloadedInfo(item: item) {
            modelPath = dl.path
            modelAlias = item.slug
        }
        if let dimsVal = item.dims {
            testEmbeddingDimensions = "\(dimsVal)"
        }
    }

    private func applyPreset(_ preset: ModelPresetEntry) {
        selectedPresetSlug = preset.slug
        slug = preset.slug
        modelName = preset.name
        dims = preset.effectiveDims > 0 ? "\(preset.effectiveDims)" : ""
        modelRef = preset.modelRef ?? preset.slug
        provider = ModelProvider.from(string: preset.provider)
        modelAlias = preset.slug
        contextSize = preset.contextSize ?? 8192
        if let dl = modelDownload.downloadedModel(for: preset.effectiveFilename ?? "") {
            modelPath = dl.path
        }
    }

    private func populateForm(from item: UnifiedModelItem) {
        slug = item.slug
        modelName = item.name
        dims = item.dims.map(String.init) ?? ""
        modelRef = item.modelRef
        provider = item.provider
        modelAlias = item.slug
        contextSize = item.contextSize ?? 8192
        if let dl = getDownloadedInfo(item: item) {
            modelPath = dl.path
        }
        if let preset = item.presetEntry {
            configMode = .preset
            selectedPresetSlug = preset.slug
        } else {
            configMode = .custom
        }
    }

    private func registerModel(item: UnifiedModelItem) {
        var args = ["register-model", item.slug, "--provider", item.provider.cliValue]
        if let dims = item.dims, dims > 0 {
            args += ["--dims", "\(dims)"]
        }
        if !item.modelRef.isEmpty && item.modelRef != item.slug {
            args += ["--model-ref", item.modelRef]
        }
        run(args)
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            await appState.runGarage(args)
            await appState.fetchRegisteredModels()
            busy = false
        }
    }

    private func runBackfill(_ args: [String]) {
        busy = true
        Task {
            await appState.runBackfill(args)
            busy = false
        }
    }

    private func linkModelFile(for item: UnifiedModelItem) {
        modelAlias = item.slug
        contextSize = item.contextSize ?? 8192
        chooseModelFile()
    }

    private func chooseModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.title = "Select GGUF Model File"
        panel.message = "Choose a .gguf model file to link and load."

        if panel.runModal() == .OK, let url = panel.url {
            modelPath = url.path
            if modelAlias.isEmpty {
                modelAlias = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private func loadCurrentModel() {
        var config: [String: Any] = [
            "n_ctx": contextSize,
            "n_gpu_layers": gpuLayers,
            "threads": cpuThreads,
        ]

        if showAdvancedConfig, !customConfigJson.isEmpty {
            if let data = customConfigJson.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in parsed {
                    config[k] = v
                }
            }
        }

        Task {
            await llama.loadModel(
                path: modelPath,
                alias: modelAlias.isEmpty ? nil : modelAlias,
                config: config
            )
        }
    }

    private func copyVectorToClipboard(vector: [Float]) {
        if let data = try? JSONSerialization.data(withJSONObject: vector, options: []),
           let jsonStr = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(jsonStr, forType: .string)
            llama.clearMessages()
        }
    }

    private func copyCSVToClipboard(vector: [Float]) {
        let formatted = vector.map { String(format: "%.8f", $0) }.joined(separator: ", ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatted, forType: .string)
    }

    private func formattedDate(_ epochSeconds: Int64) -> String {
        guard epochSeconds > 0 else { return "Unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Embedding Vector Statistics Model
struct EmbeddingVectorStats {
    let count: Int
    let min: Float
    let max: Float
    let mean: Float
    let l2Norm: Float

    init?(vector: [Float]) {
        guard !vector.isEmpty else { return nil }
        self.count = vector.count
        var minVal = vector[0]
        var maxVal = vector[0]
        var sumVal: Double = 0
        var sumSquares: Double = 0

        for val in vector {
            if val < minVal { minVal = val }
            if val > maxVal { maxVal = val }
            sumVal += Double(val)
            sumSquares += Double(val * val)
        }

        self.min = minVal
        self.max = maxVal
        self.mean = Float(sumVal / Double(vector.count))
        self.l2Norm = Float(sqrt(sumSquares))
    }
}

// Backward compatibility views
typealias EmbeddingModelsView = ModelsView
