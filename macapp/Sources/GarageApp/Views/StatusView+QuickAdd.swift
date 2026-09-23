import SwiftUI

/// First-run cards on the Status page: add the common sources and the featured
/// embedding models with one click while nothing is registered yet.
extension StatusView {
    // MARK: - Default Sources Quick Add (Empty State)

    var showDefaultSourcesQuickAdd: Bool {
        appState.postgres.status == .running && appState.registeredSources.isEmpty
    }

    var defaultSourcesQuickAddSection: some View {
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

    func quickSourceCard(for preset: SourcePreset) -> some View {
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

    func addQuickSource(_ preset: SourcePreset) {
        quickAddingSourceSlug = preset.id
        Task {
            await appState.addSource(preset.spec)
            await appState.fetchRegisteredSources()
            quickAddingSourceSlug = nil
        }
    }

    func addAllQuickSources() {
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

    var featuredModelPresets: [ModelPresetEntry] {
        appState.presetModels.filter { $0.featured }
    }

    var showFeaturedModelsQuickAdd: Bool {
        appState.postgres.status == .running && appState.registeredModels.isEmpty && !featuredModelPresets.isEmpty
    }

    var featuredModelsQuickAddSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("No text embedding models are registered yet. Add one of these recommended models to enable chunk embedding and search.")
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

    func featuredModelCard(for preset: ModelPresetEntry) -> some View {
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

    func addFeaturedModel(_ preset: ModelPresetEntry) {
        quickAddingModelSlug = preset.slug
        Task {
            await appState.registerModel(preset: preset)
            await appState.fetchRegisteredModels()
            quickAddingModelSlug = nil
        }
    }

    func addAllFeaturedModels() {
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
}
