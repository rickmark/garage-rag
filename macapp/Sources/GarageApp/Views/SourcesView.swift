import SwiftUI
import AppKit
import Combine
import IngestClient

@MainActor
struct SourcesView: View {
    @EnvironmentObject var appState: AppState

    @State private var refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    @State private var slug = ""
    @State private var root = ""
    @State private var kind = "filesystem"
    @State private var corpusClass = "document"
    @State private var trust = "authored"
    @State private var allowCloud = false

    @State private var busy = false
    @State private var ingestAutoDismissTask: Task<Void, Never>?

    private let kinds = ["filesystem", "git", "sqlite", "maildir", "feed"]
    private let classes = ["document", "code", "communication"]
    private let trusts = ["authored", "reference", "received"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskAccessSection
                ingestProgressSection
                configuredSourcesSection
                addOrUpdateSourceSection
                scheduledMaintenanceSection
                ingestOutputSection
            }
            .padding(20)
        }
        .navigationTitle("Sources & Ingest")
        .onAppear {
            refreshSourcesAndTestDisk()
        }
        .onDisappear {
            ingestAutoDismissTask?.cancel()
            ingestAutoDismissTask = nil
        }
        .onReceive(refreshTimer) { _ in
            if appState.ingestService.isRunning || appState.isScanning {
                Task {
                    await appState.fetchRegisteredSources()
                    await appState.fetchCorpusStats()
                }
            }
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
                    Button("Open Privacy Settings…") {
                        appState.openPrivacySettings(for: .fullDiskAccess)
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
                    HStack(spacing: 8) {
                        Image(systemName: testResult.isAccessible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult.isAccessible ? Color.green : Color.orange)
                            .font(.caption)
                        Text("Overall Disk Access:")
                            .font(.caption.bold())
                        Text(testResult.isAccessible ? "All Paths Accessible" : "Attention Needed")
                            .font(.caption.bold())
                            .foregroundStyle(testResult.isAccessible ? .green : .orange)
                        Spacer()
                        Text(testResult.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    // MARK: - Ingest Progress Section

    private var ingestProgressSection: some View {
        Group {
            if appState.isScanning {
                GroupBox("Scan in Progress") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning sources to update item counts and expected elements…")
                            .font(.subheadline)
                        Spacer()
                        Button("Cancel Scan") {
                            appState.cancelScan()
                        }
                        .controlSize(.small)
                    }
                    .padding(8)
                }
            }

            if appState.ingestService.isRunning || appState.ingestService.latestProgress != nil {
                GroupBox("Live Ingest Progress") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let progress = appState.ingestService.latestProgress {
                            HStack(alignment: .center, spacing: 8) {
                                if appState.ingestService.isRunning {
                                    ProgressView().controlSize(.small)
                                } else if progress.isCancelled {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.orange)
                                } else if progress.isError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }

                                Text(appState.combinedIngestTitle)
                                    .font(.headline)

                                StatusBadge(progress.phase.uppercased(), tint: .blue)
                                if let mode = appState.ingestService.activeMode {
                                    StatusBadge(mode.shortTitle.uppercased(), tint: .purple)
                                } else {
                                    StatusBadge(appState.ingestService.executionMode.shortTitle.uppercased(), tint: .purple)
                                }

                                Spacer()

                                Text(appState.combinedIngestProgressPercent)
                                    .font(.headline.monospaced())
                                    .foregroundStyle(.primary)

                                if appState.ingestService.isRunning {
                                    Button(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest") {
                                        Task { await appState.cancelIngest() }
                                    }
                                    .controlSize(.small)
                                    .disabled(appState.ingestService.isCancelling)
                                }
                            }

                            ProgressView(value: appState.combinedIngestProgressFraction)
                                .progressViewStyle(.linear)

                            HStack(spacing: 8) {
                                StatusBadge("\(appState.combinedIngestProcessedCount)/\(appState.combinedIngestTotalExpected) \(appState.combinedIngestItemType)", tint: .primary)
                                StatusBadge("\(appState.combinedIngestIndexedCount) indexed", tint: .green)
                                StatusBadge("\(appState.combinedIngestSkippedCount) skipped", tint: .secondary)
                                if appState.combinedIngestFailedCount > 0 {
                                    StatusBadge("\(appState.combinedIngestFailedCount) failed", tint: .red)
                                }
                                if appState.combinedIngestPlaceholdersCount > 0 {
                                    StatusBadge("\(appState.combinedIngestPlaceholdersCount) placeholders", tint: .orange)
                                }
                                if appState.combinedIngestChunksCount > 0 {
                                    StatusBadge("\(appState.combinedIngestChunksCount) chunks", tint: .purple)
                                }
                                Spacer()
                            }

                            if let cur = progress.currentItem, !cur.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Current:")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Text(cur)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                }
                            }

                            if !progress.message.isEmpty {
                                Text(progress.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let err = progress.error {
                                Text("Last Error: \(err)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: appState.ingestService.isRunning) { _, isRunning in
                    ingestAutoDismissTask?.cancel()
                    guard !isRunning else { return }
                    ingestAutoDismissTask = Task {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard !Task.isCancelled else { return }
                        appState.ingestService.clearTransientMessages()
                    }
                }
            }
        }
    }

    // MARK: - Configured Sources Section

    private var configuredSourcesSection: some View {
        GroupBox("Configured Ingest Sources") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(appState.registeredSources.count) source\(appState.registeredSources.count == 1 ? "" : "s") configured across config files and database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    if appState.isScanning {
                        Button("Cancel Scan") {
                            appState.cancelScan()
                        }
                    } else {
                        Button("Scan All Sources") {
                            scanAllSources()
                        }
                        .disabled(appState.registeredSources.isEmpty || notReady)
                    }

                    if appState.isIngesting {
                        Button(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest") {
                            Task { await appState.cancelIngest() }
                        }
                        .disabled(appState.ingestService.isCancelling)
                    } else {
                        Button("Ingest All Sources") {
                            ingestAllSources()
                        }
                        .disabled(appState.registeredSources.isEmpty || notReady)
                    }

                    Button("Sync Config → DB") {
                        run(["sync"])
                    }
                    .disabled(notReady)

                    Button("Import DB → Config") {
                        run(["config", "import-sources"])
                    }
                    .disabled(notReady)

                    Button("Refresh Sources") {
                        refreshSourcesAndTestDisk()
                    }
                    .disabled(appState.isFetchingSources)
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
                    VStack(spacing: 10) {
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
        let isCurrentIngest = appState.ingestService.isRunning && appState.ingestService.currentSource == source.slug

        return VStack(alignment: .leading, spacing: 8) {
            // Header Row: Slug, Badges, and Per-Source Ingest/Scan Actions
            HStack(alignment: .center, spacing: 6) {
                Text(source.slug)
                    .font(.headline)

                originBadge(for: source.origin)

                if isCurrentIngest {
                    StatusBadge("INGESTING", tint: .blue)
                }

                if source.expectedElements > 0 {
                    if source.documentCount >= source.expectedElements {
                        StatusBadge("\(source.documentCount)/\(source.expectedElements) DOCS (UP TO DATE)", tint: .green)
                    } else {
                        StatusBadge("\(source.documentCount)/\(source.expectedElements) DOCS", tint: .blue)
                        StatusBadge("\(max(0, source.expectedElements - source.documentCount)) UNINGESTED", tint: .orange)
                    }
                } else {
                    StatusBadge("\(source.documentCount) doc\(source.documentCount == 1 ? "" : "s")", tint: .blue)
                }

                if !source.enabled {
                    StatusBadge("DISABLED", tint: .secondary)
                }

                if source.allowCloudEnrichment {
                    StatusBadge("CLOUD OCR", tint: .blue)
                }

                if source.includeCode {
                    StatusBadge("CODE", tint: .purple)
                }

                if let access = accessResult {
                    if access.isAccessible {
                        StatusBadge("DISK OK", tint: .green)
                    } else if access.requiresTCCPermission || access.tccCategory != nil {
                        StatusBadge("PERMISSIONS NEEDED", tint: .orange)
                    } else {
                        StatusBadge("DISK INACCESSIBLE", tint: .red)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if isCurrentIngest {
                        Button(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel") {
                            Task { await appState.cancelIngest() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(appState.ingestService.isCancelling)
                    } else {
                        Button("Ingest") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(notReady)
                    }

                    Button("Scan") {
                        scanSource(slug: source.slug, includeCode: source.includeCode)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(notReady)

                    Menu {
                        Button("Ingest (Include Code)") {
                            ingestSource(slug: source.slug, includeCode: true)
                        }
                        .disabled(notReady)

                        Button("Ingest (Force Re-index)") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode, force: true)
                        }
                        .disabled(notReady)

                        Button("Scan Source") {
                            scanSource(slug: source.slug, includeCode: source.includeCode)
                        }
                        .disabled(notReady)

                        Button("Reconcile (Dry Run)") {
                            run(["reconcile", "--source", source.slug])
                        }
                        .disabled(notReady)

                        Button("Glean Facts") {
                            enrichFacts(source: source.slug)
                        }
                        .disabled(notReady || appState.enrichFacts.isRunning)

                        Button("Reconcile (Apply Deletions)", role: .destructive) {
                            run(["reconcile", "--source", source.slug, "--apply"])
                        }
                        .disabled(notReady)

                        Divider()

                        Button("Populate Form for Editing") {
                            populateForm(from: source)
                        }

                        if let access = accessResult, !access.isAccessible {
                            Button("Grant Directory Access…") {
                                appState.promptAndSelectSourceDirectory(slug: source.slug, suggestedPath: source.root)
                            }

                            if let cat = access.tccCategory {
                                Button("TCC Permission Prompt…") {
                                    appState.promptTCCPermission(category: cat, sourceSlug: source.slug, sourcePath: source.root)
                                }

                                Button("Open Privacy Settings…") {
                                    appState.openPrivacySettings(for: cat)
                                }
                            }
                        }

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

            // Path and configuration metadata
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

            // Ingest Results & Progress Per Source
            VStack(alignment: .leading, spacing: 4) {
                if appState.ingestService.isRunning && appState.ingestService.currentSource == source.slug,
                   let progress = appState.ingestService.latestProgress {
                    let sourceTotal = appState.sourceTotalExpected(for: source.slug)
                    let totalItems = sourceTotal > 0 ? sourceTotal : progress.totalItems
                    let sourceFraction = appState.sourceProgressFraction(for: source.slug)
                    let displayPercent = totalItems > 0 ? appState.sourceProgressPercent(for: source.slug) : progress.formattedPercent
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Ingesting (\(progress.phase)): \(displayPercent)")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        Spacer()
                        if totalItems > 0 {
                            Text("Scanned: \(progress.seen)/\(totalItems) \(progress.itemType) • Ingested: \(progress.indexed)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Scanned: \(progress.seen) \(progress.itemType) • Ingested: \(progress.indexed)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: sourceFraction)
                        .progressViewStyle(.linear)
                        .tint(.blue)

                    if let cur = progress.currentItem, !cur.isEmpty {
                        Text("Current: \(cur)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !progress.message.isEmpty {
                        Text(progress.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if appState.ingestService.pendingSources.contains(source.slug) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Pending Ingest")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text("• Queued in batch run…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if source.expectedElements > 0 {
                            Text("0/\(source.expectedElements) items")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if source.expectedElements > 0 {
                        ProgressView(
                            value: Double(source.documentCount),
                            total: Double(max(source.documentCount, source.expectedElements))
                        )
                        .progressViewStyle(.linear)
                    }
                } else if source.documentCount == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("Pending Ingest:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        if source.expectedElements > 0 {
                            Text("\(source.expectedElements) item\(source.expectedElements == 1 ? "" : "s") found by scan • Not yet ingested")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No documents indexed yet • Ready to ingest")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if source.expectedElements > 0 {
                        ProgressView(
                            value: 0.0,
                            total: Double(source.expectedElements)
                        )
                        .progressViewStyle(.linear)
                    }
                } else if let progress = appState.ingestService.progressBySource[source.slug] {
                    let sourceTotal = appState.sourceTotalExpected(for: source.slug)
                    let totalItems = sourceTotal > 0 ? sourceTotal : progress.totalItems
                    HStack {
                        Image(systemName: progress.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(progress.isError ? Color.red : Color.green)
                            .font(.caption)
                        Text("Last Ingest (\(progress.phase)): \(progress.indexed) ingested, \(progress.skipped) skipped, \(progress.failed) failed")
                            .font(.caption)
                        Spacer()
                        if totalItems > 0 {
                            Text("Scanned: \(progress.seen)/\(totalItems) \(progress.itemType)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else if progress.seen > 0 {
                            Text("Scanned: \(progress.seen) \(progress.itemType)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if totalItems > 0 {
                        let processed = max(source.documentCount, progress.indexed, progress.seen)
                        ProgressView(
                            value: Double(processed),
                            total: Double(max(processed, totalItems))
                        )
                        .progressViewStyle(.linear)
                    } else if source.expectedElements > 0 {
                        ProgressView(
                            value: Double(source.documentCount),
                            total: Double(max(source.documentCount, source.expectedElements))
                        )
                        .progressViewStyle(.linear)
                    }
                } else {
                    HStack {
                        Text("Ingest Status:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        if source.expectedElements > 0 {
                            let uningested = max(0, source.expectedElements - source.documentCount)
                            Text("\(source.documentCount) of \(source.expectedElements) documents ingested (\(uningested) uningested)")
                                .font(.caption)
                        } else {
                            Text("\(source.documentCount) document\(source.documentCount == 1 ? "" : "s") indexed in database")
                                .font(.caption)
                        }
                        Spacer()
                    }

                    if source.expectedElements > 0 {
                        ProgressView(
                            value: Double(source.documentCount),
                            total: Double(max(source.documentCount, source.expectedElements))
                        )
                        .progressViewStyle(.linear)
                    }
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Test Results & Disk Access Per Source
            if let access = accessResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: access.isAccessible ? "checkmark.circle.fill" : (access.requiresTCCPermission ? "lock.shield.fill" : "xmark.circle.fill"))
                            .foregroundStyle(access.isAccessible ? Color.green : (access.requiresTCCPermission ? Color.orange : Color.red))
                            .font(.caption)

                        Text("Disk Access Test:")
                            .font(.caption.bold())

                        Text(access.statusDescription)
                            .font(.caption)
                            .foregroundStyle(access.isAccessible ? Color.secondary : (access.requiresTCCPermission ? Color.orange : Color.red))

                        if let count = access.itemCount, count > 0 {
                            Text("(\(count) item\(count == 1 ? "" : "s") found)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if access.rawPath != access.resolvedPath {
                            Text("• Resolved: \(access.resolvedPath)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()
                    }

                    if !access.isAccessible {
                        let cat = access.tccCategory ?? TCCPermissionCategory.detect(slug: source.slug, path: source.root)

                        if let help = access.tccHelpMessage ?? cat?.helpMessage {
                            Text(help)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button("Grant Folder Access…") {
                                appState.promptAndSelectSourceDirectory(slug: source.slug, suggestedPath: source.root)
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)

                            if let cat = cat {
                                Button("TCC Prompt…") {
                                    appState.promptTCCPermission(category: cat, sourceSlug: source.slug, sourcePath: source.root)
                                }
                                .controlSize(.small)

                                Button("Open Privacy Settings…") {
                                    appState.openPrivacySettings(for: cat)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(6)
                .background((access.isAccessible ? Color.primary.opacity(0.03) : (access.requiresTCCPermission ? Color.orange : Color.red).opacity(0.08)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func originBadge(for origin: RegisteredSource.SourceOrigin) -> some View {
        switch origin {
        case .config:
            return StatusBadge("CONFIG", tint: .orange)
        case .database:
            return StatusBadge("DB", tint: .teal)
        case .both:
            return StatusBadge("CONFIG & DB", tint: .indigo)
        }
    }


    // MARK: - Add / Update Source Section

    private var addOrUpdateSourceSection: some View {
        GroupBox("Add / Update a Source") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Quick Presets:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Menu("Choose preset…") {
                        ForEach(SourcePreset.all) { preset in
                            Button(preset.title) {
                                applyPreset(preset)
                            }
                        }
                    }
                    .controlSize(.small)

                    Spacer()

                    if !appState.registeredSources.isEmpty {
                        Text("Fill from existing:")
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
            let combinedLogs = appState.combinedIngestLogs
            if !combinedLogs.isEmpty {
                GroupBox("Ingest output") {
                    LogTableView(
                        lines: combinedLogs,
                        sourceName: "Ingest",
                        onClear: {
                            appState.clearLogs(for: "Ingest")
                        }
                    )
                    .frame(minHeight: 200, maxHeight: 350)
                }
            }
        }
    }

    // MARK: - Helpers

    private var notReady: Bool {
        appState.postgres.status != .running || busy || appState.isIngesting || appState.isScanning
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

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            root = url.path
        }
    }

    private func applyPreset(_ preset: SourcePreset) {
        slug = preset.spec.slug
        root = preset.spec.root
        kind = preset.spec.kind
        corpusClass = preset.spec.corpusClass
        trust = preset.spec.trust
        allowCloud = preset.spec.allowCloudEnrichment
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

    private func scanSource(slug: String, includeCode: Bool = false) {
        guard !appState.isIngesting else { return }
        busy = true
        Task {
            await appState.scanSources(source: slug, includeCode: includeCode)
            busy = false
        }
    }

    private func scanAllSources() {
        guard !appState.isIngesting else { return }
        busy = true
        Task {
            await appState.scanSources(source: "*")
            busy = false
        }
    }

    private func ingestSource(slug: String, includeCode: Bool = false, force: Bool = false) {
        busy = true
        Task {
            let options = IngestOptions(includeCode: includeCode, force: force)
            _ = await appState.ingestSource(slug: slug, options: options)
            busy = false
        }
    }

    private func ingestAllSources() {
        busy = true
        Task {
            _ = await appState.ingestSource(slug: "*")
            busy = false
        }
    }

    private func addOrUpdateSource() {
        busy = true
        let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = SourceSpec(
            slug: trimmedSlug,
            root: trimmedRoot,
            kind: kind,
            corpusClass: corpusClass,
            trust: trust,
            allowCloudEnrichment: allowCloud
        )
        Task {
            await appState.addSource(spec)
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

    private func enrichFacts(source: String) {
        Task {
            await appState.runEnrichFacts(["enrich-facts", "--source", source])
        }
    }

}
