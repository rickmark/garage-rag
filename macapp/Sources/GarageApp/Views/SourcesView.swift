import SwiftUI
import AppKit

struct SourcesView: View {
    @EnvironmentObject var appState: AppState

    @State private var slug = ""
    @State private var root = ""
    @State private var kind = "filesystem"
    @State private var corpusClass = "document"
    @State private var trust = "authored"
    @State private var allowCloud = false

    @State private var ingestSlug = "*"
    @State private var includeCode = false
    @State private var forceReindex = false

    @State private var busy = false

    private let kinds = ["filesystem", "git", "sqlite", "maildir", "feed"]
    private let classes = ["document", "code", "communication"]
    private let trusts = ["authored", "reference", "received"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Add / update a source") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Slug") {
                            TextField("dropbox", text: $slug).textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Root") {
                            HStack {
                                TextField("/Users/you/Dropbox", text: $root).textFieldStyle(.roundedBorder)
                                Button("Choose…") { chooseRoot() }
                            }
                        }
                        Picker("Kind", selection: $kind) {
                            ForEach(kinds, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Class", selection: $corpusClass) {
                            ForEach(classes, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Trust", selection: $trust) {
                            ForEach(trusts, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("Allow cloud OCR fallback", isOn: $allowCloud)
                            .disabled(corpusClass == "communication")

                        HStack {
                            Button("Add source") { run(["add-source", slug, root, "--kind", kind, "--class", corpusClass, "--trust", trust] + (allowCloud ? ["--allow-cloud-enrichment"] : [])) }
                                .disabled(slug.isEmpty || root.isEmpty || notReady)
                            Button("List sources") { run(["list-sources"]) }
                                .disabled(notReady)
                            Button("Remove source") { run(["remove-source", slug, "--yes"]) }
                                .disabled(slug.isEmpty || notReady)
                        }
                    }
                    .padding(8)
                }

                GroupBox("Ingest") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Source slug") {
                            TextField("* for all sources", text: $ingestSlug).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Include code files", isOn: $includeCode)
                        Toggle("Force re-extract & re-chunk", isOn: $forceReindex)
                        HStack {
                            Button("Ingest now") {
                                var args = ["ingest", "--source", ingestSlug]
                                if includeCode { args.append("--include-code") }
                                if forceReindex { args.append("--force") }
                                runIngest(args)
                            }
                            .disabled(ingestSlug.isEmpty || notReady)

                            Button("Reconcile (dry run)") { run(["reconcile", "--source", ingestSlug]) }
                                .disabled(ingestSlug.isEmpty || notReady)

                            if busy { ProgressView().controlSize(.small) }
                        }
                        Text("Ingest can take a long time for large sources; output streams below as it runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Scheduled maintenance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Run ingest and backfill automatically", isOn: $appState.scheduledMaintenanceEnabled)
                        Picker("Every", selection: $appState.scheduledMaintenanceInterval) {
                            Text("15 minutes").tag(TimeInterval(15 * 60))
                            Text("1 hour").tag(TimeInterval(60 * 60))
                            Text("6 hours").tag(TimeInterval(6 * 60 * 60))
                            Text("24 hours").tag(TimeInterval(24 * 60 * 60))
                        }
                        .disabled(!appState.scheduledMaintenanceEnabled)
                        Text("Each run ingests all sources, then backfills all registered models. The first run starts after the selected interval.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                if !appState.ingest.logs.isEmpty {
                    GroupBox("Ingest output") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(appState.ingest.logs) { line in
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
        .navigationTitle("Sources & Ingest")
    }

    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
        }
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            await appState.runGarage(args)
            busy = false
        }
    }

    private func runIngest(_ args: [String]) {
        busy = true
        Task {
            await appState.runIngest(args)
            busy = false
        }
    }
}
