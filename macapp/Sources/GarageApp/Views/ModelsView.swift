import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var appState: AppState

    @State private var slug = "bge-m3"
    @State private var dims = ""
    @State private var modelRef = ""
    @State private var makeDefault = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Register / manage a model") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Slug") {
                            TextField("bge-m3", text: $slug).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Dims (optional)") {
                            TextField("leave blank for known models", text: $dims).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Model ref (optional)") {
                            TextField("provider-side name, if different", text: $modelRef).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Make default", isOn: $makeDefault)

                        HStack {
                            Button("Register") {
                                var args = ["register-model", slug]
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
                        Text("Embeds chunks that a model has no vectors for yet. Requires Ollama running locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Backfill \(slug.isEmpty ? "all models" : slug)") {
                                run(slug.isEmpty ? ["backfill"] : ["backfill", "--model", slug])
                            }
                            .disabled(notReady)
                        }
                    }
                    .padding(8)
                }

                if !appState.lastCommandOutput.isEmpty {
                    GroupBox("Output") {
                        ScrollView {
                            Text(appState.lastCommandOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
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

    private func run(_ args: [String]) {
        busy = true
        Task {
            await appState.runGarage(args)
            busy = false
        }
    }
}
