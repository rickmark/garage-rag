import SwiftUI
import AppKit
import LlamaClient

struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    // Model selection & registration state
    @State private var selectedModel = KnownModel.bgeM3
    @State private var slug = "bge-m3"
    @State private var dims = "1024"
    @State private var modelRef = "bge-m3"
    @State private var provider = ModelProvider.llamaXPC
    @State private var makeDefault = false
    @State private var busy = false
    @State private var lmStudioToken = ""

    // Llama model linking & configuration state
    @State private var modelPath: String = ""
    @State private var modelAlias: String = "bge-m3"
    @State private var contextSize: Int = 8192
    @State private var gpuLayers: Int = 33
    @State private var cpuThreads: Int = 4
    @State private var showAdvancedConfig: Bool = false
    @State private var customConfigJson: String = "{}"
    @State private var showUnloadConfirmation: Bool = false

    // Testing Playground state
    @State private var testPrompt: String = "Hello! Tell me a one-sentence joke."
    @State private var testMaxTokens: Int = 64

    private var llama: LlamaService {
        appState.llama
    }

    enum KnownModel: String, CaseIterable, Identifiable {
        case bgeM3 = "BGE-M3 (Embeddings)"
        case nomicEmbedText = "Nomic Embed Text"
        case mxbaiEmbedLarge = "mxbai Embed Large"
        case embeddingGemma = "Embedding Gemma"
        case snowflakeArcticEmbed2 = "Snowflake Arctic Embed 2"
        case qwen3Embedding06B = "Qwen 3 Embedding 0.6B"
        case qwen3Embedding4B = "Qwen 3 Embedding 4B"
        case qwen3Embedding8B = "Qwen 3 Embedding 8B"
        case llama32_1b = "Llama 3.2 1B (Instruct)"
        case llama32_3b = "Llama 3.2 3B (Instruct)"
        case qwen25_7b = "Qwen 2.5 7B (Coder)"
        case mistral7b = "Mistral 7B (Instruct)"
        case custom = "Custom Model"

        var id: String { rawValue }

        var displayName: String { rawValue }

        var defaults: (slug: String, dims: String, modelRef: String, provider: ModelProvider, defaultContextSize: Int)? {
            switch self {
            case .bgeM3:
                return ("bge-m3", "1024", "bge-m3", .llamaXPC, 8192)
            case .nomicEmbedText:
                return ("nomic-embed-text", "768", "nomic-embed-text", .ollama, 8192)
            case .mxbaiEmbedLarge:
                return ("mxbai-embed-large", "1024", "mxbai-embed-large", .ollama, 8192)
            case .embeddingGemma:
                return ("embeddinggemma", "768", "embeddinggemma", .ollama, 8192)
            case .snowflakeArcticEmbed2:
                return ("snowflake-arctic-embed2", "1024", "snowflake-arctic-embed2", .ollama, 8192)
            case .qwen3Embedding06B:
                return ("qwen3-embedding-0.6b", "1024", "qwen3-embedding:0.6b", .ollama, 8192)
            case .qwen3Embedding4B:
                return ("qwen3-embedding-4b", "2560", "qwen3-embedding:4b", .ollama, 8192)
            case .qwen3Embedding8B:
                return ("qwen3-embedding-8b", "4096", "qwen3-embedding:8b", .ollama, 8192)
            case .llama32_1b:
                return ("llama-3.2-1b-instruct", "", "llama-3.2-1b-instruct", .llamaXPC, 8192)
            case .llama32_3b:
                return ("llama-3.2-3b-instruct", "", "llama-3.2-3b-instruct", .llamaXPC, 8192)
            case .qwen25_7b:
                return ("qwen-2.5-coder-7b", "", "qwen-2.5-coder-7b", .llamaXPC, 16384)
            case .mistral7b:
                return ("mistral-7b-instruct", "", "mistral-7b-instruct", .llamaXPC, 8192)
            case .custom:
                return nil
            }
        }
    }

    enum ModelProvider: String, CaseIterable, Identifiable {
        case llamaXPC = "Llama XPC"
        case ollama = "Ollama"
        case lmStudio = "LM Studio"

        var id: Self { self }

        var displayName: String { rawValue }

        var cliValue: String {
            switch self {
            case .llamaXPC: "llama_xpc"
            case .ollama: "ollama"
            case .lmStudio: "lmstudio"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section 1: Model Catalog & Registration
                registrationSection

                // Section 2: Link Llama Model (GGUF)
                linkLlamaModelSection

                // Section 3: Backfill Embeddings
                backfillSection

                // Section 4: LM Studio API Token
                if provider == .lmStudio || appState.lmStudioTokenConfigured {
                    lmStudioTokenSection
                }

                // Section 5: Llama XPC Service Status & Playground
                llamaServiceSection

                // Section 6: Output / Feedback
                outputSection
            }
            .padding(20)
        }
        .navigationTitle("Models")
        .task {
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

    // MARK: - Model Catalog & Registration Section

    private var registrationSection: some View {
        GroupBox("Model Configuration & Registration") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(KnownModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .onChange(of: selectedModel) { _, model in
                    applyDefaults(for: model)
                }

                LabeledContent("Slug") {
                    TextField("bge-m3", text: $slug)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: slug) { _, newSlug in
                            if modelAlias.isEmpty || modelAlias == slug {
                                modelAlias = newSlug
                            }
                        }
                }

                LabeledContent("Dims (optional)") {
                    TextField("required for custom models", text: $dims)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Model Ref (optional)") {
                    TextField("provider-side name, if different", text: $modelRef)
                        .textFieldStyle(.roundedBorder)
                }

                Picker("Provider", selection: $provider) {
                    ForEach(ModelProvider.allCases) { prov in
                        Text(prov.displayName).tag(prov)
                    }
                }

                Toggle("Make default model", isOn: $makeDefault)

                HStack {
                    Button("Register \(provider.displayName)") {
                        var args = ["register-model", slug, "--provider", provider.cliValue]
                        if !dims.isEmpty { args += ["--dims", dims] }
                        if !modelRef.isEmpty { args += ["--model-ref", modelRef] }
                        if makeDefault { args.append("--default") }
                        run(args)
                    }
                    .disabled(slug.isEmpty || notReady)

                    Button("List registered models") { run(["list-models"]) }
                        .disabled(notReady)

                    Button("Set default") { run(["set-default-model", slug]) }
                        .disabled(slug.isEmpty || notReady)

                    Button("Drop", role: .destructive) { run(["drop-model", slug, "--yes"]) }
                        .disabled(slug.isEmpty || notReady)

                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Link Llama Model Section

    private var linkLlamaModelSection: some View {
        GroupBox("Link Llama Model (GGUF)") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Link and load a local GGUF model into the Llama XPC service for this model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let activeModelId = llama.activeModelId, llama.health?.status != "no_model_loaded" {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active Model: \(activeModelId)")
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

                    if llama.isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Backfill Section

    private var backfillSection: some View {
        GroupBox("Backfill embeddings") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Embeds chunks that a model has no vectors for yet. Start the provider selected when the model was registered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Backfill \(slug.isEmpty ? "all models" : slug)") {
                        runBackfill(slug.isEmpty ? ["backfill"] : ["backfill", "--model", slug])
                    }
                    .disabled(notReady)
                }
            }
            .padding(8)
        }
    }

    // MARK: - LM Studio Token Section

    private var lmStudioTokenSection: some View {
        GroupBox("LM Studio API token") {
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

    // MARK: - Llama Service & Playground Section

    private var llamaServiceSection: some View {
        GroupBox("Llama XPC Service & Verification") {
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

                // Interactive Playground
                Divider()
                Text("Verification Playground")
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
                    Button("Generate / Verify") {
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

    // MARK: - Output Section

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
                            Text("Completion Output:")
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

    // MARK: - Helpers

    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    private func applyDefaults(for model: KnownModel) {
        guard let defaults = model.defaults else { return }
        slug = defaults.slug
        dims = defaults.dims
        modelRef = defaults.modelRef
        provider = defaults.provider
        modelAlias = defaults.slug
        contextSize = defaults.defaultContextSize
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            await appState.runGarage(args)
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

    private func formattedDate(_ epochSeconds: Int64) -> String {
        guard epochSeconds > 0 else { return "Unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// Backward compatibility views
typealias EmbeddingModelsView = ModelsView
