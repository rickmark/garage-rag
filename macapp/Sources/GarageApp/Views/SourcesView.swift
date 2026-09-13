import SwiftUI
import AppKit
import IngestClient

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

    // Arbitrary Ingest Parameters State
    @State private var customSourceSlug: String = "*"
    @State private var customSourceInput: String = ""
    @State private var customExecutionMode: IngestExecutionMode = .xpcService
    @State private var customIncludeCode: Bool = false
    @State private var customForce: Bool = false
    @State private var customLimitEnabled: Bool = false
    @State private var customLimitValue: Int = 10
    @State private var customArbitraryArgs: String = ""
    @State private var customGrpcHost: String = ""
    @State private var customGrpcPort: String = ""
    @State private var showAdvancedOptions: Bool = false
    @State private var showCopiedAlert: Bool = false

    @State private var busy = false

    private let kinds = ["filesystem", "git", "sqlite", "maildir", "feed"]
    private let classes = ["document", "code", "communication"]
    private let trusts = ["authored", "reference", "received"]

    private struct SourcePreset: Identifiable {
        let id: String
        let title: String
        let slug: String
        let root: String
        let kind: String
        let corpusClass: String
        let trust: String
        let allowCloud: Bool
    }

    private let commonPresets: [SourcePreset] = [
        SourcePreset(id: "apple-sms", title: "Messages (apple-sms)", slug: "apple-sms", root: "~/Library/Messages", kind: "sqlite", corpusClass: "communication", trust: "received", allowCloud: false),
        SourcePreset(id: "apple-mail", title: "Apple Mail (apple-mail)", slug: "apple-mail", root: "~/Library/Mail", kind: "maildir", corpusClass: "communication", trust: "received", allowCloud: false),
        SourcePreset(id: "documents", title: "Documents", slug: "documents", root: "~/Documents", kind: "filesystem", corpusClass: "document", trust: "authored", allowCloud: false),
        SourcePreset(id: "downloads", title: "Downloads", slug: "downloads", root: "~/Downloads", kind: "filesystem", corpusClass: "document", trust: "received", allowCloud: false),
        SourcePreset(id: "desktop", title: "Desktop", slug: "desktop", root: "~/Desktop", kind: "filesystem", corpusClass: "document", trust: "authored", allowCloud: false)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskAccessSection
                ingestProgressSection
                configuredSourcesSection
                runIngestWithCustomParametersSection
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

                                Text(progress.source.isEmpty ? "Ingestion" : progress.source)
                                    .font(.headline)

                                badgeText(progress.phase.uppercased(), bg: Color.blue.opacity(0.15), fg: .blue)
                                if let mode = appState.ingestService.activeMode {
                                    badgeText(mode.shortTitle.uppercased(), bg: Color.purple.opacity(0.15), fg: .purple)
                                } else {
                                    badgeText(appState.ingestService.executionMode.shortTitle.uppercased(), bg: Color.purple.opacity(0.15), fg: .purple)
                                }

                                Spacer()

                                Text(progress.formattedPercent)
                                    .font(.headline.monospaced())
                                    .foregroundStyle(.primary)

                                if appState.ingestService.isRunning {
                                    Button(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest") {
                                        Task { await appState.cancelIngest() }
                                    }
                                    .controlSize(.small)
                                    .disabled(appState.ingestService.isCancelling)
                                } else {
                                    Button("Dismiss") {
                                        appState.ingestService.clearMessages()
                                    }
                                    .controlSize(.small)
                                }
                            }

                            ProgressView(value: progress.progress)
                                .progressViewStyle(.linear)

                            HStack(spacing: 8) {
                                badgeText("\(progress.seen)/\(progress.totalItems) \(progress.itemType)", bg: Color.primary.opacity(0.06), fg: .primary)
                                badgeText("\(progress.indexed) indexed", bg: Color.green.opacity(0.15), fg: .green)
                                badgeText("\(progress.skipped) skipped", bg: Color.gray.opacity(0.15), fg: .secondary)
                                if progress.failed > 0 {
                                    badgeText("\(progress.failed) failed", bg: Color.red.opacity(0.15), fg: .red)
                                }
                                if progress.placeholders > 0 {
                                    badgeText("\(progress.placeholders) placeholders", bg: Color.orange.opacity(0.15), fg: .orange)
                                }
                                if progress.chunksWritten > 0 {
                                    badgeText("\(progress.chunksWritten) chunks", bg: Color.purple.opacity(0.15), fg: .purple)
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
            }
        }
    }

    // MARK: - Configured Sources Section

    private var configuredSourcesSection: some View {
        GroupBox("Configured Ingest Sources") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Ingest Execution Mode:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("Ingest Mode", selection: $appState.ingestService.executionMode) {
                        ForEach(IngestExecutionMode.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    Text(appState.ingestService.executionMode.modeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)

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
                        Menu {
                            Button("Ingest All (\(appState.ingestService.executionMode.shortTitle))") {
                                ingestAllSources()
                            }
                            Button("Ingest All via XPC Helper") {
                                ingestAllSources(mode: .xpcService)
                            }
                            Button("Ingest All via In-Process") {
                                ingestAllSources(mode: .inProcess)
                            }
                            Button("Ingest All via CLI Process") {
                                ingestAllSources(mode: .cliProcess)
                            }
                        } label: {
                            Text("Ingest All Sources")
                        } primaryAction: {
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
                    badgeText("INGESTING", bg: Color.blue.opacity(0.15), fg: .blue)
                }

                if source.expectedElements > 0 {
                    if source.documentCount >= source.expectedElements {
                        badgeText("\(source.documentCount)/\(source.expectedElements) DOCS (UP TO DATE)", bg: Color.green.opacity(0.15), fg: .green)
                    } else {
                        badgeText("\(source.documentCount)/\(source.expectedElements) DOCS", bg: Color.blue.opacity(0.15), fg: .blue)
                        badgeText("\(max(0, source.expectedElements - source.documentCount)) UNINGESTED", bg: Color.orange.opacity(0.15), fg: .orange)
                    }
                } else {
                    badgeText("\(source.documentCount) doc\(source.documentCount == 1 ? "" : "s")", bg: Color.blue.opacity(0.15), fg: .blue)
                }

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
                    } else if access.requiresTCCPermission || access.tccCategory != nil {
                        badgeText("PERMISSIONS NEEDED", bg: Color.orange.opacity(0.15), fg: .orange)
                    } else {
                        badgeText("DISK INACCESSIBLE", bg: Color.red.opacity(0.15), fg: .red)
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
                        Button("Ingest (\(appState.ingestService.executionMode.shortTitle))") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode)
                        }

                        Button("Ingest via XPC Helper") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode, mode: .xpcService)
                        }

                        Button("Ingest via In-Process") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode, mode: .inProcess)
                        }

                        Button("Ingest via CLI Process") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode, mode: .cliProcess)
                        }

                        Divider()

                        Button("Ingest (Include Code)") {
                            ingestSource(slug: source.slug, includeCode: true)
                        }

                        Button("Ingest (Force Re-index)") {
                            ingestSource(slug: source.slug, includeCode: source.includeCode, force: true)
                        }

                        Button("Scan Source") {
                            scanSource(slug: source.slug, includeCode: source.includeCode)
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
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Ingesting (\(progress.phase)): \(progress.formattedPercent)")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        Spacer()
                        Text("Scanned: \(progress.seen)/\(progress.totalItems) \(progress.itemType) • Ingested: \(progress.indexed)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress.progress)
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
                } else if let progress = appState.ingestService.progressBySource[source.slug] {
                    HStack {
                        Image(systemName: progress.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(progress.isError ? Color.red : Color.green)
                            .font(.caption)
                        Text("Last Ingest (\(progress.phase)): \(progress.indexed) ingested, \(progress.skipped) skipped, \(progress.failed) failed")
                            .font(.caption)
                        Spacer()
                        if progress.totalItems > 0 {
                            Text("Scanned: \(progress.seen)/\(progress.totalItems) \(progress.itemType)")
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

    // MARK: - Run Ingest with Arbitrary Parameters Section

    private var runIngestWithCustomParametersSection: some View {
        GroupBox("Run Ingest with Arbitrary Parameters") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Execute the ingest command with standard options, quick presets, or arbitrary CLI parameters across any execution mode (XPC Helper, In-Process, or CLI Process).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Presets Bar
                HStack(spacing: 8) {
                    Text("Presets:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    Button("All Sources (Default)") {
                        applyIngestPreset(.allSourcesDefault)
                    }
                    .controlSize(.small)

                    Button("Trial Run (Limit 10)") {
                        applyIngestPreset(.trialRun10)
                    }
                    .controlSize(.small)

                    Button("Force Re-index All") {
                        applyIngestPreset(.forceAll)
                    }
                    .controlSize(.small)

                    Button("Include Code") {
                        applyIngestPreset(.includeCodeAll)
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Reset Parameters") {
                        resetCustomIngestParameters()
                    }
                    .controlSize(.small)
                }

                Divider()

                // Source Selection & Mode
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Target Source:")
                            .font(.caption.bold())
                            .frame(width: 130, alignment: .leading)

                        HStack(spacing: 8) {
                            Picker("Source", selection: $customSourceSlug) {
                                Text("* (All Registered Sources)").tag("*")
                                Divider()
                                ForEach(appState.registeredSources) { src in
                                    Text("\(src.slug) (\(src.kind))").tag(src.slug)
                                }
                                Divider()
                                Text("Custom Slug / Path…").tag("__custom__")
                            }
                            .frame(maxWidth: 240)

                            if customSourceSlug == "__custom__" {
                                TextField("Enter slug or path (e.g. apple-sms, ~/Documents)", text: $customSourceInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)
                            }
                        }
                    }

                    GridRow {
                        Text("Execution Mode:")
                            .font(.caption.bold())

                        Picker("Execution Mode", selection: $customExecutionMode) {
                            ForEach(IngestExecutionMode.allCases) { mode in
                                Text(mode.shortTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }
                }

                Divider()

                // Standard Options & Toggles
                VStack(alignment: .leading, spacing: 8) {
                    Text("Standard Options:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        Toggle("Include Code (--include-code)", isOn: $customIncludeCode)
                            .help("Also index programming source code files, not just documents.")

                        Toggle("Force Re-extract (--force)", isOn: $customForce)
                            .help("Re-extract and re-chunk files even if unchanged since previous ingest.")

                        HStack(spacing: 6) {
                            Toggle("Limit (--limit):", isOn: $customLimitEnabled)
                            if customLimitEnabled {
                                TextField("10", value: $customLimitValue, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Stepper("", value: $customLimitValue, in: 1...1_000_000)
                                    .labelsHidden()
                            }
                        }
                    }
                }

                // Arbitrary Parameters Text Input
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Arbitrary Parameters / Extra CLI Flags:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("e.g. --limit 50 --force --include-code --grpc-port 50051")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    TextField("Enter arbitrary parameters or CLI arguments (e.g. --limit 20 --force)", text: $customArbitraryArgs)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("Arbitrary flags entered here are parsed and passed directly to the ingest engine or CLI subprocess. Quotes and escapes are supported.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Advanced gRPC options (collapsible)
                DisclosureGroup("Advanced gRPC & Service Options", isExpanded: $showAdvancedOptions) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Text("gRPC Host:")
                                    .font(.caption.bold())
                                TextField("127.0.0.1", text: $customGrpcHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 140)
                            }

                            HStack(spacing: 6) {
                                Text("gRPC Port:")
                                    .font(.caption.bold())
                                TextField("50051", text: $customGrpcPort)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                // Live Command Preview & Copy
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Generated Command Preview:")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(action: {
                            copyPreviewToClipboard()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: showCopiedAlert ? "checkmark" : "doc.on.doc")
                                Text(showCopiedAlert ? "Copied!" : "Copy Command")
                            }
                        }
                        .controlSize(.small)
                    }

                    HStack {
                        Text(generatedCommandLinePreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                // Run & Action Row
                HStack(spacing: 12) {
                    if appState.ingestService.isRunning {
                        Button(action: {
                            Task { await appState.cancelIngest() }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                Text(appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(appState.ingestService.isCancelling)

                        ProgressView().controlSize(.small)

                        Text("Ingestion is currently running (\(appState.ingestService.currentSource ?? "source"))…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: {
                            runCustomIngest()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Run Ingest Command")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(notReady || isCustomSlugInvalid)

                        if busy {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Spacer()

                    if let lastSuccess = appState.ingestService.lastSuccess {
                        Text(lastSuccess)
                            .font(.caption)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    } else if let lastError = appState.ingestService.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
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
                        ForEach(commonPresets) { preset in
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
        slug = preset.slug
        root = preset.root
        kind = preset.kind
        corpusClass = preset.corpusClass
        trust = preset.trust
        allowCloud = preset.allowCloud
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
        busy = true
        Task {
            await appState.scanSources(source: slug, includeCode: includeCode)
            busy = false
        }
    }

    private func scanAllSources() {
        busy = true
        Task {
            await appState.scanSources(source: "*")
            busy = false
        }
    }

    private func ingestSource(slug: String, includeCode: Bool = false, force: Bool = false, mode: IngestExecutionMode? = nil) {
        busy = true
        Task {
            let options = IngestOptions(includeCode: includeCode, force: force)
            _ = await appState.ingestSource(slug: slug, options: options, mode: mode)
            busy = false
        }
    }

    private func ingestAllSources(mode: IngestExecutionMode? = nil) {
        busy = true
        Task {
            _ = await appState.ingestSource(slug: "*", mode: mode)
            busy = false
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
            await appState.fetchRegisteredSources()
            await appState.fetchCorpusStats()
            busy = false
        }
    }

    // MARK: - Arbitrary Parameters Helpers

    private enum IngestCustomPreset {
        case allSourcesDefault
        case trialRun10
        case forceAll
        case includeCodeAll
    }

    private func applyIngestPreset(_ preset: IngestCustomPreset) {
        switch preset {
        case .allSourcesDefault:
            customSourceSlug = "*"
            customIncludeCode = false
            customForce = false
            customLimitEnabled = false
            customArbitraryArgs = ""
        case .trialRun10:
            customSourceSlug = "*"
            customIncludeCode = false
            customForce = false
            customLimitEnabled = true
            customLimitValue = 10
            customArbitraryArgs = ""
        case .forceAll:
            customSourceSlug = "*"
            customIncludeCode = false
            customForce = true
            customLimitEnabled = false
            customArbitraryArgs = ""
        case .includeCodeAll:
            customSourceSlug = "*"
            customIncludeCode = true
            customForce = false
            customLimitEnabled = false
            customArbitraryArgs = ""
        }
    }

    private func resetCustomIngestParameters() {
        customSourceSlug = "*"
        customSourceInput = ""
        customIncludeCode = false
        customForce = false
        customLimitEnabled = false
        customLimitValue = 10
        customArbitraryArgs = ""
        customGrpcHost = ""
        customGrpcPort = ""
        customExecutionMode = appState.ingestService.executionMode
    }

    private var effectiveCustomSlug: String {
        if customSourceSlug == "__custom__" {
            let trimmed = customSourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "*" : trimmed
        }
        return customSourceSlug
    }

    private var isCustomSlugInvalid: Bool {
        if customSourceSlug == "__custom__" {
            return customSourceInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private var parsedExtraArguments: [String] {
        CommandLineParser.splitArguments(customArbitraryArgs)
    }

    private var generatedCommandLinePreview: String {
        var parts = ["garage", "ingest"]
        let slug = effectiveCustomSlug
        parts.append(contentsOf: ["--source", slug])
        if customIncludeCode {
            parts.append("--include-code")
        }
        if customForce {
            parts.append("--force")
        }
        if customLimitEnabled {
            parts.append(contentsOf: ["--limit", "\(customLimitValue)"])
        }
        let host = customGrpcHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty {
            parts.append(contentsOf: ["--grpc-host", host])
        }
        let portStr = customGrpcPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(portStr), port > 0 {
            parts.append(contentsOf: ["--grpc-port", "\(port)"])
        }
        if !customArbitraryArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(contentsOf: parsedExtraArguments)
        }
        return parts.joined(separator: " ")
    }

    private func copyPreviewToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(generatedCommandLinePreview, forType: .string)
        showCopiedAlert = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showCopiedAlert = false
        }
    }

    private func runCustomIngest() {
        busy = true
        let slug = effectiveCustomSlug
        let limit = customLimitEnabled ? customLimitValue : nil
        let host = customGrpcHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(customGrpcPort.trimmingCharacters(in: .whitespacesAndNewlines))
        let extraArgs = parsedExtraArguments

        let options = IngestOptions(
            includeCode: customIncludeCode,
            limit: limit,
            force: customForce,
            grpcHost: host.isEmpty ? nil : host,
            grpcPort: port,
            extraArguments: extraArgs
        )

        Task {
            _ = await appState.ingestSource(
                slug: slug,
                options: options,
                mode: customExecutionMode
            )
            busy = false
        }
    }
}
