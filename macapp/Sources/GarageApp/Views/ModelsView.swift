import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedModel = KnownEmbeddingModel.bgeM3
    @State private var slug = "bge-m3"
    @State private var dims = "1024"
    @State private var modelRef = "bge-m3"
    @State private var provider = EmbeddingProvider.ollama
    @State private var makeDefault = false
    @State private var busy = false
    @State private var lmStudioToken = ""

    private enum KnownEmbeddingModel: String, CaseIterable, Identifiable {
        case bgeM3
        case nomicEmbedText
        case mxbaiEmbedLarge
        case embeddingGemma
        case snowflakeArcticEmbed2
        case qwen3Embedding06B
        case qwen3Embedding4B
        case qwen3Embedding8B
        case custom

        var id: Self { self }

        var displayName: String {
            switch self {
            case .bgeM3: "bge-m3"
            case .nomicEmbedText: "nomic-embed-text"
            case .mxbaiEmbedLarge: "mxbai-embed-large"
            case .embeddingGemma: "embeddinggemma"
            case .snowflakeArcticEmbed2: "snowflake-arctic-embed2"
            case .qwen3Embedding06B: "qwen3-embedding-0.6b"
            case .qwen3Embedding4B: "qwen3-embedding-4b"
            case .qwen3Embedding8B: "qwen3-embedding-8b"
            case .custom: "Custom"
            }
        }

        var defaults: (slug: String, dims: String, modelRef: String, provider: EmbeddingProvider)? {
            switch self {
            case .bgeM3: ("bge-m3", "1024", "bge-m3", .ollama)
            case .nomicEmbedText: ("nomic-embed-text", "768", "nomic-embed-text", .ollama)
            case .mxbaiEmbedLarge: ("mxbai-embed-large", "1024", "mxbai-embed-large", .ollama)
            case .embeddingGemma: ("embeddinggemma", "768", "embeddinggemma", .ollama)
            case .snowflakeArcticEmbed2:
                ("snowflake-arctic-embed2", "1024", "snowflake-arctic-embed2", .ollama)
            case .qwen3Embedding06B:
                ("qwen3-embedding-0.6b", "1024", "qwen3-embedding:0.6b", .ollama)
            case .qwen3Embedding4B:
                ("qwen3-embedding-4b", "2560", "qwen3-embedding:4b", .ollama)
            case .qwen3Embedding8B:
                ("qwen3-embedding-8b", "4096", "qwen3-embedding:8b", .ollama)
            case .custom: nil
            }
        }
    }

    private enum EmbeddingProvider: String, CaseIterable, Identifiable {
        case ollama
        case lmStudio

        var id: Self { self }

        var displayName: String {
            switch self {
            case .ollama: "Ollama"
            case .lmStudio: "LM Studio"
            }
        }

        var cliValue: String {
            switch self {
            case .ollama: "ollama"
            case .lmStudio: "lmstudio"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Register / manage a model") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Model", selection: $selectedModel) {
                            ForEach(KnownEmbeddingModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .onChange(of: selectedModel) { _, model in
                            applyDefaults(for: model)
                        }
                        LabeledContent("Slug") {
                            TextField("bge-m3", text: $slug).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Dims (optional)") {
                            TextField("required for custom models", text: $dims).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model ref (optional)") {
                            TextField("provider-side name, if different", text: $modelRef).textFieldStyle(.roundedBorder)
                        }
                        Picker("Provider", selection: $provider) {
                            ForEach(EmbeddingProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        Toggle("Make default", isOn: $makeDefault)

                        HStack {
                            Button("Register \(provider.displayName)") {
                                var args = ["register-model", slug, "--provider", provider.cliValue]
                                if !dims.isEmpty { args += ["--dims", dims] }
                                if !modelRef.isEmpty { args += ["--model-ref", modelRef] }
                                if makeDefault { args.append("--default") }
                                run(args)
                            }
                            .disabled(slug.isEmpty || notReady)

                            Button("List models") { run(["list-models"]) }
                                .disabled(notReady)
                            Button("Set default") { run(["set-default-model", slug]) }
                                .disabled(slug.isEmpty || notReady)
                            Button("Drop", role: .destructive) { run(["drop-model", slug, "--yes"]) }
                                .disabled(slug.isEmpty || notReady)

                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(8)
                }

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
                        .frame(maxHeight: 320)
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Embedding Models")
    }

    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    private func applyDefaults(for model: KnownEmbeddingModel) {
        guard let defaults = model.defaults else { return }
        slug = defaults.slug
        dims = defaults.dims
        modelRef = defaults.modelRef
        provider = defaults.provider
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
}
