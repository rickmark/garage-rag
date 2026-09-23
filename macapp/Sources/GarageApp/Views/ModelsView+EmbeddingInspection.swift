import SwiftUI
import AppKit
import LlamaClient

extension ModelsView {
    // MARK: - Section 4: Non-Truncated Embedding Testing & Inspection

    var embeddingInspectionSection: some View {
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
                                StatusBadge(selectedTestModelSlug.uppercased(), tint: .purple)
                            }
                            StatusBadge("\(stats.count) DIMENSIONS", tint: .green)
                            StatusBadge("NO TRUNCATION", tint: .blue)
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
