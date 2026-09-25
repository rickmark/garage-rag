import SwiftUI

/// The fact-extraction prompts on the Models page: the built-in `default` and any
/// in `facts.prompts`, each with an on/off switch, an editor and a Run button.
/// Every change is written back whole through `SetSetting facts.prompts`, which
/// validates it before garage.json is touched.
struct FactPromptsSection: View {
    @EnvironmentObject var appState: AppState
    /// The prompt being edited, and the name it had when the sheet opened (nil for a new one).
    @State private var editing: FactPromptEditorState?

    private var notReady: Bool {
        appState.postgres.status != .running
    }

    var body: some View {
        GroupBox("Fact Prompts") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text("Glean Facts runs every enabled prompt that applies to a document; each fact records the prompt that produced it. Stored in garage.json under facts.prompts, merged by name with the built-in default.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("New Prompt") {
                        let names = Set(appState.factPrompts.map(\.name))
                        editing = FactPromptEditorState(prompt: .blank(existingNames: names), originalName: nil)
                    }
                    .disabled(notReady)
                }

                if let error = appState.factPromptsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if appState.factPrompts.isEmpty {
                    Text(appState.postgres.status == .running ? "Loading prompts…" : "Start the database to see the prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(appState.factPrompts) { prompt in
                            row(for: prompt)
                        }
                    }
                }
            }
            .padding(8)
        }
        .task {
            await appState.fetchFactPrompts()
        }
        .sheet(item: $editing) { state in
            FactPromptEditor(state: state) { saved in
                await save(saved, replacing: state.originalName)
            }
        }
    }

    private func row(for prompt: FactPromptItem) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { prompt.enabled },
                set: { enabled in
                    let json = FactPromptConfig.settingEnabled(enabled, for: prompt.name, in: appState.factPromptsConfiguredJSON)
                    Task { await appState.saveFactPrompts(configuredJSON: json) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(notReady)
            .help(prompt.enabled ? "Enabled: Glean Facts runs this prompt" : "Disabled: runs only when asked for by name")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(prompt.name)
                        .font(.callout.monospaced().bold())
                    if prompt.builtin {
                        StatusBadge(prompt.customized ? "BUILT-IN, CUSTOMIZED" : "BUILT-IN", tint: .blue)
                    }
                    if !prompt.enabled {
                        StatusBadge("DISABLED", tint: .secondary)
                    }
                }
                Text("\(prompt.scopeSummary) · \(prompt.sha256.prefix(12))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(prompt.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            Button("Run") {
                Task { await appState.runEnrichFacts(prompts: [prompt.name]) }
            }
            .disabled(notReady || appState.enrichFacts.isRunning)
            .help("Glean facts from every document with just this prompt")

            Button("Edit") {
                var copy = prompt
                copy.examplesJSON = FactPromptConfig.prettyExamples(prompt.examplesJSON)
                editing = FactPromptEditorState(prompt: copy, originalName: prompt.name)
            }
            .disabled(notReady)

            if !prompt.builtin {
                Button("Delete", role: .destructive) {
                    let json = FactPromptConfig.removing(prompt.name, from: appState.factPromptsConfiguredJSON)
                    Task { await appState.saveFactPrompts(configuredJSON: json) }
                }
                .disabled(notReady)
            } else if prompt.customized {
                Button("Restore") {
                    let json = FactPromptConfig.removing(prompt.name, from: appState.factPromptsConfiguredJSON)
                    Task { await appState.saveFactPrompts(configuredJSON: json) }
                }
                .disabled(notReady)
                .help("Drop the override and use the built-in prompt as shipped")
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    /// Validates and writes the edited prompt; a thrown message is shown in the sheet.
    private func save(_ prompt: FactPromptItem, replacing originalName: String?) async -> String? {
        var names = Set(appState.factPrompts.map(\.name))
        if let originalName {
            names.remove(originalName)
        }
        do {
            let json = try FactPromptConfig.saving(
                prompt,
                replacing: originalName,
                in: appState.factPromptsConfiguredJSON,
                existingNames: names
            )
            let succeeded = await appState.saveFactPrompts(configuredJSON: json)
            return succeeded ? nil : appState.lastCommandOutput
        } catch {
            return error.localizedDescription
        }
    }
}

struct FactPromptEditorState: Identifiable {
    let id = UUID()
    var prompt: FactPromptItem
    var originalName: String?
}

/// Name, instructions, examples (JSON), scope and on/off for one prompt.
struct FactPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: FactPromptItem
    @State private var sourcesText: String
    @State private var error: String?
    @State private var saving = false
    private let isNew: Bool
    private let onSave: (FactPromptItem) async -> String?

    init(state: FactPromptEditorState, onSave: @escaping (FactPromptItem) async -> String?) {
        _prompt = State(initialValue: state.prompt)
        _sourcesText = State(initialValue: state.prompt.sources.joined(separator: ", "))
        isNew = state.originalName == nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Fact Prompt" : "Edit Fact Prompt")
                .font(.headline)

            Form {
                TextField("Name", text: $prompt.name)
                    .disabled(prompt.builtin)
                    .help(prompt.builtin ? "A built-in prompt keeps its name" : "Letters, digits, '.', '_' or '-'")
                Toggle("Enabled", isOn: $prompt.enabled)
                LabeledContent("Corpus classes") {
                    HStack {
                        ForEach(FactPromptConfig.corpusClasses, id: \.self) { corpusClass in
                            Toggle(corpusClass, isOn: classBinding(corpusClass))
                                .toggleStyle(.checkbox)
                        }
                        Text("(none checked = all)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Sources", text: $sourcesText, prompt: Text("source slugs, comma-separated; empty = all"))
            }

            Text("Instructions")
                .font(.subheadline.bold())
            TextEditor(text: $prompt.description)
                .font(.body)
                .frame(minHeight: 110)
                .border(Color.secondary.opacity(0.3))

            Text("Examples (JSON: text plus the extractions expected from it, each with class, text and optional attributes)")
                .font(.subheadline.bold())
            TextEditor(text: $prompt.examplesJSON)
                .font(.caption.monospaced())
                .frame(minHeight: 160)
                .border(Color.secondary.opacity(0.3))

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 620)
    }

    private func classBinding(_ corpusClass: String) -> Binding<Bool> {
        Binding(
            get: { prompt.corpusClasses.contains(corpusClass) },
            set: { on in
                prompt.corpusClasses.removeAll { $0 == corpusClass }
                if on {
                    prompt.corpusClasses.append(corpusClass)
                }
                prompt.corpusClasses.sort {
                    (FactPromptConfig.corpusClasses.firstIndex(of: $0) ?? 0)
                        < (FactPromptConfig.corpusClasses.firstIndex(of: $1) ?? 0)
                }
            }
        )
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var edited = prompt
        edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.sources = sourcesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let message = await onSave(edited) {
            error = message
        } else {
            dismiss()
        }
    }
}
