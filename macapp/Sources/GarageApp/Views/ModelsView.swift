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
    @State private var customSha256: String = ""
    @State private var makeDefault: Bool = false
    @State private var busy: Bool = false
    @State private var lmStudioToken: String = ""

    // Llama model loading configuration state
    @State private var modelAlias: String = "bge-m3"
    @State private var contextSize: Int = 8192
    @State private var gpuLayers: Int = 33
    @State private var cpuThreads: Int = 4
    @State private var showUnloadConfirmation: Bool = false

    // Testing Playground state
    @State private var selectedTestModelSlug: String = ""
    @State private var testPrompt: String = "Garage provides local retrieval-augmented generation for personal archives."
    @State private var testEmbeddingDimensions: String = ""
    @State private var showCopiedAlert: Bool = false
    @State private var searchText: String = ""
    @State private var registeringPresetSlug: String? = nil

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
        let sha256: String?
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

        var effectiveSha256: String? {
            sha256 ?? presetEntry?.sha256 ?? catalogItem?.sha256
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
                    sha256: preset?.sha256 ?? catItem?.sha256,
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

    /// Presets from `models.json` that aren't registered yet, with featured presets surfaced first.
    private var unregisteredPresetModels: [ModelPresetEntry] {
        let registeredSlugs = Set(appState.registeredModels.map(\.slug))
        return appState.presetModels
            .filter { !registeredSlugs.contains($0.slug) }
            .sorted { lhs, rhs in
                if lhs.featured != rhs.featured {
                    return lhs.featured && !rhs.featured
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Registered Models List & Status
                modelCatalogSection

                // Section 1.5: Available Models (Not Yet Registered)
                if !unregisteredPresetModels.isEmpty {
                    availableModelsSection
                }

                // Section 2: Model Configuration & Registration (Preset or Custom)
                configurationSection

                // Section 4: Non-Truncated Embedding Testing & Inspection
                embeddingInspectionSection

                // Section 5: LM Studio API Token
                if provider == .lmStudio || appState.lmStudioTokenConfigured {
                    lmStudioTokenSection
                }

                // Section 6: Llama XPC Service Status
                llamaServiceSection

                // Section 7: Backfill Output
                backfillOutputSection

                // Section 8: Output / Feedback
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

                    if !modelDownload.downloadedModels.isEmpty {
                        Button("Verify All SHA-256") {
                            verifyAllDownloadedModels()
                        }
                        .controlSize(.small)
                        .disabled(modelDownload.isBusy)
                    }

                    Button("Backfill All (*)") {
                        backfillAllModels()
                    }
                    .disabled(appState.registeredModels.isEmpty || notReady || appState.backfill.isRunning)

                    Button("Refresh") {
                        refreshAll()
                    }
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

    private func modelCard(for item: UnifiedModelItem) -> some View {
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

                            if isVerifying {
                                badgeText("VERIFYING SHA-256…", bg: Color.blue.opacity(0.18), fg: .blue)
                            } else if let v = verification {
                                if v.isValid {
                                    badgeText("SHA-256 VERIFIED", bg: Color.green.opacity(0.18), fg: .green)
                                } else {
                                    badgeText("SHA-256 MISMATCH", bg: Color.red.opacity(0.18), fg: .red)
                                }
                            } else if item.effectiveSha256 != nil {
                                badgeText("SHA-256 UNVERIFIED", bg: Color.secondary.opacity(0.15), fg: .secondary)
                            }
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

                    if let expectedSha = item.effectiveSha256 {
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
                            Text("Computed SHA-256: \(v.computedSha256)")
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

                        // Verify SHA-256 button for downloaded file
                        Button {
                            Task {
                                await modelDownload.verifyModelFile(path: dl.path, expectedSha256: item.effectiveSha256)
                            }
                        } label: {
                            if isVerifying {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("Verify SHA-256", systemImage: "checkmark.shield")
                            }
                        }
                        .controlSize(.small)
                        .disabled(isVerifying)
                        .help("Verify file SHA-256 checksum against preset specification")
                    }

                    // Backfill Embeddings button
                    if item.isRegistered {
                        Button("Backfill") {
                            backfillModel(slug: item.slug)
                        }
                        .controlSize(.small)
                        .disabled(notReady || appState.backfill.isRunning)
                    }

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

                        if let expectedSha = item.effectiveSha256 {
                            Button("Copy Expected SHA-256") {
                                modelDownload.copyToClipboard(text: expectedSha)
                            }
                        }

                        if !item.isRegistered {
                            Button("Register in Database") {
                                registerModel(item: item)
                            }
                            .disabled(notReady)
                        } else {
                            Button("Backfill Embeddings") {
                                backfillModel(slug: item.slug)
                            }
                            .disabled(notReady || appState.backfill.isRunning)

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
                            Button("Verify SHA-256 Checksum") {
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
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
            }

            // Embedding progress details for model
            if item.isRegistered {
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
                            badgeText("100% EMBEDDED", bg: Color.green.opacity(0.18), fg: .green)
                        } else {
                            Text("\(embeddedCount) / \(totalChunks) chunks (\(percentText)) • \(remaining) remaining")
                                .font(.caption.monospaced())
                            badgeText("\(remaining) PENDING", bg: Color.orange.opacity(0.18), fg: .orange)
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
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Section 1.5: Available Models (Not Yet Registered)

    private var availableModelsSection: some View {
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

    private func availablePresetCard(_ preset: ModelPresetEntry) -> some View {
        let isRegistering = registeringPresetSlug == preset.slug

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.subheadline.bold())
                    if preset.featured {
                        badgeText("FEATURED", bg: Color.green.opacity(0.15), fg: .green)
                    }
                    if preset.effectiveDims > 0 {
                        badgeText("\(preset.effectiveDims) DIMS", bg: Color.blue.opacity(0.12), fg: .blue)
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

    private func registerPreset(_ preset: ModelPresetEntry) {
        registeringPresetSlug = preset.slug
        var args = ["register-model", preset.slug, "--provider", preset.provider ?? "llama_xpc"]
        if preset.effectiveDims > 0 {
            args += ["--dims", "\(preset.effectiveDims)"]
        }
        if let ref = preset.modelRef, !ref.isEmpty, ref != preset.slug {
            args += ["--model-ref", ref]
        }
        Task {
            await appState.runGarage(args)
            await appState.fetchRegisteredModels()
            registeringPresetSlug = nil
        }
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

                    LabeledContent("SHA-256 Hash (optional)") {
                        TextField("Expected SHA-256 hex digest for file verification", text: $customSha256)
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

    // MARK: - Section 4: Non-Truncated Embedding Testing & Inspection

    private var embeddingInspectionSection: some View {
        GroupBox("Embeddings Inspection & Testing (Full Vector)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Test and inspect the complete embedding vector of any model without truncation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Model") {
                    Picker("Model", selection: $selectedTestModelSlug) {
                        Text("Active / Default Model").tag("")
                        ForEach(unifiedModels) { m in
                            Text("\(m.name) (\(m.slug))").tag(m.slug)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedTestModelSlug) { _, newSlug in
                        if !newSlug.isEmpty, let matched = unifiedModels.first(where: { $0.slug == newSlug }) {
                            if let dimsVal = matched.dims {
                                testEmbeddingDimensions = "\(dimsVal)"
                            }
                            modelAlias = matched.slug
                        }
                    }
                }

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
                        let targetModel = selectedTestModelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await llama.testEmbedding(
                                text: testPrompt,
                                model: targetModel.isEmpty ? nil : targetModel,
                                dimensions: parsedDims
                            )
                        }
                    }
                    .disabled(llama.isBusy || (llama.health?.status == "no_model_loaded" && selectedTestModelSlug.isEmpty) || testPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                            if !selectedTestModelSlug.isEmpty {
                                badgeText(selectedTestModelSlug.uppercased(), bg: Color.purple.opacity(0.15), fg: .purple)
                            }
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

    // MARK: - Section 6: Llama Service Status Section

    private var llamaServiceSection: some View {
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

    // MARK: - Section 7: Backfill Output Section

    private var backfillOutputSection: some View {
        Group {
            if !appState.backfill.logs.isEmpty {
                GroupBox("Embedding Backfill Output") {
                    LogTableView(
                        lines: appState.backfill.logs,
                        sourceName: "Backfill",
                        onClear: { appState.backfill.clearLogs() }
                    )
                    .frame(minHeight: 180, maxHeight: 300)
                }
            }
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
            await appState.fetchCorpusStats()
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

    private func getActiveDownloadTask(item: UnifiedModelItem) -> DownloadTaskInfo? {
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
                modelId: item.slug,
                sha256: item.effectiveSha256
            )
        }
    }

    private func verifyAllDownloadedModels() {
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
        selectedTestModelSlug = item.slug
        modelAlias = item.slug
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
    }

    private func populateForm(from item: UnifiedModelItem) {
        slug = item.slug
        modelName = item.name
        dims = item.dims.map(String.init) ?? ""
        modelRef = item.modelRef
        provider = item.provider
        modelAlias = item.slug
        contextSize = item.contextSize ?? 8192
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

    private func backfillModel(slug: String) {
        busy = true
        Task {
            await appState.runBackfill(["backfill", "--model", slug])
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            busy = false
        }
    }

    private func backfillAllModels() {
        busy = true
        Task {
            await appState.runBackfill(["backfill", "--model", "*"])
            await appState.fetchCorpusStats()
            await appState.fetchRegisteredModels()
            busy = false
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
