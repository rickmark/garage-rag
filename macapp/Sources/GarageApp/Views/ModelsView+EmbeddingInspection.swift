import SwiftUI
import AppKit
import LlamaClient

extension ModelsView {
    // MARK: - Test an embedding

    /// Embed a sentence with a registered model and look at the whole vector, folded away until
    /// asked for: a check that a model answers, and the numbers when something looks off.
    var embeddingTestSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $showEmbeddingTest) {
                embeddingTestContent
                    .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text("Test an Embedding")
                        .font(.headline)
                    Text("Embed a sentence and inspect the full vector")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    var embeddingTestContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Model", selection: $selectedTestModelSlug) {
                    Text("Loaded model").tag("")
                    ForEach(unifiedModels) { m in
                        Text(m.name).tag(m.slug)
                    }
                }
                .frame(maxWidth: 320)
                .onChange(of: selectedTestModelSlug) { _, newSlug in
                    if !newSlug.isEmpty, let matched = unifiedModels.first(where: { $0.slug == newSlug }) {
                        if let dimsVal = matched.dims {
                            testEmbeddingDimensions = "\(dimsVal)"
                        }
                    }
                }

                LabeledContent("Dimensions") {
                    TextField("model's", text: $testEmbeddingDimensions)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .help("Truncate the vector to this many dimensions (Matryoshka models); empty keeps the model's own")

                Spacer()
            }

            TextEditor(text: $testPrompt)
                .font(.body)
                .frame(height: 56)
                .padding(4)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))

            HStack(spacing: 8) {
                Button("Embed") {
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
                .buttonStyle(.borderedProminent)
                .disabled(llama.isBusy || (llama.health?.status == "no_model_loaded" && selectedTestModelSlug.isEmpty) || testPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if llama.isBusy {
                    ProgressView().controlSize(.small)
                }

                if let vector = llama.lastEmbeddingVector, !vector.isEmpty {
                    Spacer()
                    Button("Copy JSON") {
                        copyVectorToClipboard(vector: vector)
                    }
                    .controlSize(.small)
                    Button("Copy CSV") {
                        copyCSVToClipboard(vector: vector)
                    }
                    .controlSize(.small)
                }
            }

            if let err = llama.lastError, llama.lastEmbeddingVector == nil {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let vector = llama.lastEmbeddingVector, let stats = EmbeddingVectorStats(vector: vector) {
                HStack(spacing: 8) {
                    statBox(title: "Dimensions", value: "\(stats.count)")
                    statBox(title: "Min", value: String(format: "%.6f", stats.min))
                    statBox(title: "Max", value: String(format: "%.6f", stats.max))
                    statBox(title: "Mean", value: String(format: "%.6f", stats.mean))
                    statBox(title: "L2 norm", value: String(format: "%.6f", stats.l2Norm))
                }

                // The whole vector, never truncated: the point of the test when a model misbehaves.
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
                .frame(height: 160)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    func statBox(title: String, value: String) -> some View {
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
