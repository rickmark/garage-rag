import SwiftUI
import AppKit

@MainActor
struct SourcesView: View {
    @EnvironmentObject var appState: AppState

    @State private var slug = ""
    @State private var root = ""
    @State private var kind = "filesystem"
    @State private var corpusClass = "document"
    @State private var trust = "authored"
    @State private var allowCloud = false
    @State private var includeCodeInSource = false

    @State private var ingestSelection = "*"
    @State private var customIngestSlug = ""
    @State private var includeCode = false
    @State private var forceReindex = false

    @State private var busy = false

    private let kinds = ["filesystem", "git", "sqlite", "maildir", "feed"]
    private let classes = ["document", "code", "communication"]
    private let trusts = ["authored", "reference", "received"]

    var effectiveIngestSlug: String {
        if ingestSelection == "custom" {
            return customIngestSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ingestSelection
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskAccessSection
                configuredSourcesSection
                addOrUpdateSourceSection
                ingestSection
                scheduledMaintenanceSection
                ingestOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Sources & Ingest")
        .onAppear {
            refreshSourcesAndTestDisk()
        }
    }

    // MARK: - Disk Access Section

    private var diskAccessSection: some View {
        GroupBox("App Sandbox & Disk Access") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: volumeStatusIcon)
                        .font(.title2)
                        .foregroundStyle(volumeStatusColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(volumeStatusTitle)
                            .fontWeight(.semibold)
                        Text(appState.volumeAccess.status.displayDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text("To allow Garage to ingest documents across your system within the macOS Sandbox, select your root hard-drive (e.g. Macintosh HD or '/'). Disk access is verified for each configured ingest source path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Select Root Hard Drive…") {
                        appState.promptAndSelectRootVolume()
                        _ = appState.testVolumeAccess()
                    }
                    Button("Test Ingest Paths & Disk Access") {
                        _ = appState.testVolumeAccess()
                    }
                    if appState.volumeAccess.status.isGranted {
                        Button("Revoke Access") {
                            appState.revokeVolumeAccess()
                        }
                        .foregroundStyle(.red)
                    }
                }

                if let testResult = appState.volumeAccess.lastTestResult {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Test Result:")
                                .font(.caption.bold())
                            Text(testResult.isAccessible ? "Passed" : "Attention Needed")
                                .font(.caption.bold())
                                .foregroundStyle(testResult.isAccessible ? .green : .red)
                        }

                        Text(testResult.message)
                            .font(.caption)

                        if !testResult.sourcePathResults.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ingest Source Paths:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)

                                ForEach(testResult.sourcePathResults) { res in
                                    sourcePathResultRow(res)
                                }
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else if !testResult.accessibleSubpaths.isEmpty {
                            Text("Accessible root directories: \(testResult.accessibleSubpaths.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    // MARK: - Configured Sources Section

    private var configuredSourcesSection: some View {
        GroupBox("Configured Ingest Sources") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(appState.registeredSources.count) source\(appState.registeredSources.count == 1 ? "" : "s") configured across config files and database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh Sources") {
                        refreshSourcesAndTestDisk()
                    }
                    .disabled(appState.isFetchingSources)

                    Button("Sync Config → DB") {
                        run(["sync"])
                    }
                    .disabled(notReady)

                    Button("Import DB → Config") {
                        run(["config", "import-sources"])
                    }
                    .disabled(notReady)

                    Button("List Sources (CLI)") {
                        run(["list-sources"])
                    }
                    .disabled(notReady)
                }

                if appState.registeredSources.isEmpty {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No sources configured yet.")
                            .font(.headline)
                        Text("Add a source below, or define sources in your ~/.garage.json config file and click 'Sync Config → DB'.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.registeredSources) { source in
                            sourceCard(for: source)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func sourceCard(for source: RegisteredSource) -> some View {
        let accessResult = appState.volumeAccess.lastTestResult?.sourcePathResults.first {
            $0.slug == source.slug || $0.rawPath == source.root
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(source.slug)
                            .font(.headline)

                        originBadge(for: source.origin)

                        if !source.enabled {
                            badgeText("DISABLED", bg: Color.gray.opacity(0.2), fg: .secondary)
                        }

                        if source.allowCloudEnrichment {
                            badgeText("CLOUD OCR", bg: Color.blue.opacity(0.15), fg: .blue)
                        }

                        if source.includeCode {
                            badgeText("CODE", bg: Color.purple.opacity(0.15), fg: .purple)
                        }

                        if let access = accessResult {
                            if access.isAccessible {
                                badgeText("DISK OK", bg: Color.green.opacity(0.15), fg: .green)
                            } else {
                                badgeText("DISK INACCESSIBLE", bg: Color.red.opacity(0.15), fg: .red)
                            }
                        }
                    }

                    HStack(spacing: 4) {
                        Text("Path:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(source.root)
                            .font(.caption.monospaced())
                        if source.root.hasPrefix("~") {
                            Text("(\(source.expandedRootPath))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Kind: \(source.kind) • Class: \(source.corpusClass) • Trust: \(source.trust)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let access = accessResult, !access.isAccessible {
                        Text("Disk Access Status: \(access.statusDescription)")
                            .font(.caption2.bold())
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Ingest") {
                        ingestSelection = source.slug
                        includeCode = source.includeCode
                        var args = ["ingest", "--source", source.slug]
                        if source.includeCode { args.append("--include-code") }
                        runIngest(args)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(notReady)

                    Menu {
                        Button("Select in Ingest Form") {
                            ingestSelection = source.slug
                            includeCode = source.includeCode
                        }

                        Button("Populate Form for Editing") {
                            populateForm(from: source)
                        }

                        Button("Reconcile (Dry Run)") {
                            run(["reconcile", "--source", source.slug])
                        }
                        .disabled(notReady)

                        Button("Reconcile (Apply Deletions)", role: .destructive) {
                            run(["reconcile", "--source", source.slug, "--apply"])
                        }
                        .disabled(notReady)

                        Divider()

                        Button("Remove Source", role: .destructive) {
                            removeSource(slug: source.slug)
                        }
                        .disabled(notReady)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 24)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func originBadge(for origin: RegisteredSource.SourceOrigin) -> some View {
        switch origin {
        case .config:
            return badgeText("CONFIG", bg: Color.orange.opacity(0.15), fg: .orange)
        case .database:
            return badgeText("DB", bg: Color.teal.opacity(0.15), fg: .teal)
        case .both:
            return badgeText("CONFIG & DB", bg: Color.indigo.opacity(0.15), fg: .indigo)
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

    // MARK: - Add / Update Source Section

    private var addOrUpdateSourceSection: some View {
        GroupBox("Add / Update a Source") {
            VStack(alignment: .leading, spacing: 10) {
                if !appState.registeredSources.isEmpty {
                    HStack {
                        Text("Fill from existing source:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Menu("Select source…") {
                            ForEach(appState.registeredSources) { src in
                                Button(src.slug) {
                                    populateForm(from: src)
                                }
                            }
                        }
                        .controlSize(.small)
                        Spacer()
                    }
                }

                LabeledContent("Slug") {
                    TextField("dropbox", text: $slug).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Root") {
                    HStack {
                        TextField("~/Dropbox", text: $root).textFieldStyle(.roundedBorder)
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
                    Button("Add / Update Source") {
                        addOrUpdateSource()
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)

                    Button("Remove Source", role: .destructive) {
                        removeSource(slug: slug)
                    }
                    .disabled(slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || notReady)

                    Button("Clear Form") {
                        slug = ""
                        root = ""
                        kind = "filesystem"
                        corpusClass = "document"
                        trust = "authored"
                        allowCloud = false
                    }

                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Ingest Section

    private var ingestSection: some View {
        GroupBox("Ingest Corpus") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Source to Ingest") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $ingestSelection) {
                            Text("All Sources (*)").tag("*")
                            ForEach(appState.registeredSources) { src in
                                Text("\(src.slug) (\(src.root))").tag(src.slug)
                            }
                            Text("Custom Slug…").tag("custom")
                        }
                        .labelsHidden()

                        if ingestSelection == "custom" {
                            TextField("Enter source slug", text: $customIngestSlug)
                                .textFieldStyle(.roundedBorder)
                        } else if let selectedSource = appState.registeredSources.first(where: { $0.slug == ingestSelection }) {
                            HStack(spacing: 8) {
                                Text("Path: \(selectedSource.root)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)

                                if let access = appState.volumeAccess.lastTestResult?.sourcePathResults.first(where: { $0.slug == selectedSource.slug }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: access.isAccessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(access.isAccessible ? Color.green : Color.red)
                                        Text(access.statusDescription)
                                            .foregroundStyle(access.isAccessible ? Color.secondary : Color.red)
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                    }
                }

                Toggle("Include code files", isOn: $includeCode)
                Toggle("Force re-extract & re-chunk", isOn: $forceReindex)

                HStack {
                    Button("Ingest now") {
                        var args = ["ingest", "--source", effectiveIngestSlug]
                        if includeCode { args.append("--include-code") }
                        if forceReindex { args.append("--force") }
                        runIngest(args)
                    }
                    .disabled(effectiveIngestSlug.isEmpty || notReady)

                    Button("Reconcile (dry run)") {
                        run(["reconcile", "--source", effectiveIngestSlug])
                    }
                    .disabled(effectiveIngestSlug.isEmpty || notReady)

                    if busy { ProgressView().controlSize(.small) }
                }

                Text("Ingest walks files from the selected source(s), chunks and extracts metadata into Postgres.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Scheduled Maintenance Section

    private var scheduledMaintenanceSection: some View {
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
    }

    // MARK: - Ingest Output Section

    private var ingestOutputSection: some View {
        Group {
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
    }

    // MARK: - Helpers

    private var notReady: Bool {
        appState.postgres.status != .running || busy
    }

    private var volumeStatusIcon: String {
        switch appState.volumeAccess.status {
        case .accessGranted:
            return "checkmark.seal.fill"
        case .staleBookmark:
            return "exclamationmark.triangle.fill"
        case .accessDenied:
            return "xmark.octagon.fill"
        case .notConfigured:
            return "lock.trianglebadge.exclamationmark"
        }
    }

    private var volumeStatusColor: Color {
        switch appState.volumeAccess.status {
        case .accessGranted:
            return .green
        case .staleBookmark:
            return .yellow
        case .accessDenied:
            return .red
        case .notConfigured:
            return .orange
        }
    }

    private var volumeStatusTitle: String {
        switch appState.volumeAccess.status {
        case .accessGranted:
            return "Full Volume Access Granted"
        case .staleBookmark:
            return "Root Volume Bookmark Stale"
        case .accessDenied:
            return "Full Volume Access Denied"
        case .notConfigured:
            return "Root Hard Drive Not Selected"
        }
    }

    private func sourcePathResultRow(_ res: SourcePathAccessResult) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: res.isAccessible ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(res.isAccessible ? Color.green : Color.red)
                .font(.caption)

            Text(res.slug.isEmpty ? res.rawPath : res.slug)
                .font(.caption.bold().monospaced())

            Text(res.rawPath)
                .font(.caption.monospaced())
                .foregroundStyle(Color.secondary)

            if res.rawPath != res.resolvedPath {
                Text("(\(res.resolvedPath))")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }

            Spacer()

            Text(res.statusDescription)
                .font(.caption2)
                .foregroundStyle(res.isAccessible ? Color.secondary : Color.red)
        }
        .padding(.vertical, 2)
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

    private func populateForm(from source: RegisteredSource) {
        slug = source.slug
        root = source.root
        kind = source.kind
        corpusClass = source.corpusClass
        trust = source.trust
        allowCloud = source.allowCloudEnrichment
    }

    private func refreshSourcesAndTestDisk() {
        Task {
            await appState.fetchRegisteredSources()
            _ = appState.testVolumeAccess()
        }
    }

    private func addOrUpdateSource() {
        busy = true
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["add-source", trimmedSlug, trimmedRoot, "--kind", kind, "--class", corpusClass, "--trust", trust]
        if allowCloud {
            args.append("--allow-cloud-enrichment")
        }
        Task {
            await appState.runGarage(args)
            await appState.fetchRegisteredSources()
            _ = appState.testVolumeAccess()
            busy = false
        }
    }

    private func removeSource(slug toRemove: String) {
        busy = true
        let trimmed = toRemove.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await appState.runGarage(["remove-source", trimmed, "--yes"])
            await appState.fetchRegisteredSources()
            _ = appState.testVolumeAccess()
            busy = false
        }
    }

    private func run(_ args: [String]) {
        busy = true
        Task {
            await appState.runGarage(args)
            await appState.fetchRegisteredSources()
            _ = appState.testVolumeAccess()
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
