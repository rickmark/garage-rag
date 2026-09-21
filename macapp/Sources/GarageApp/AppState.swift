import Foundation
import SwiftUI
import Combine
import OSLog
import IngestClient

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    private static let scheduledMaintenanceEnabledKey = "scheduledMaintenanceEnabled"
    private static let scheduledMaintenanceIntervalKey = "scheduledMaintenanceInterval"
    private static let maintenanceTriggeringCommands: Set<String> = ["add-source", "register-model"]

    let postgres = PostgresService()
    let garage: GarageCLIService
    let ingest: GarageCLIService
    let backfill: GarageCLIService
    let mcp: GarageMCPService
    let grpc: GarageGRPCService
    let llama: LlamaService
    let modelDownload: ModelDownloadService
    let volumeAccess: VolumeAccessService
    @Published var ingestService: IngestService
    let xpcServices: XPCServiceManager
    @Published var osLogStreamService: OSLogStreamService
    private var cancellables = Set<AnyCancellable>()

    /// Output of the most recent manual or scheduled `garage` command,
    /// separate from the rolling activity log.
    @Published var lastCommandOutput: String = ""
    @Published var lastCommandSucceeded: Bool?
    @Published var autoStartPostgres = true
    @Published private(set) var lmStudioTokenConfigured = false
    @Published private(set) var presetModels: [ModelPresetEntry] = []
    @Published private(set) var registeredModels: [RegisteredModel] = []
    @Published private(set) var isFetchingModels = false
    @Published var registeredSources: [RegisteredSource] = []
    @Published private(set) var isFetchingSources = false
    @Published var corpusStats = CorpusStats()
    @Published private(set) var isFetchingStats = false
    @Published private(set) var isApplyingMigrations = false
    @Published var scheduledMaintenanceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                scheduledMaintenanceEnabled,
                forKey: Self.scheduledMaintenanceEnabledKey
            )
            configureScheduledMaintenance()
        }
    }
    @Published var scheduledMaintenanceInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(
                scheduledMaintenanceInterval,
                forKey: Self.scheduledMaintenanceIntervalKey
            )
            configureScheduledMaintenance()
        }
    }

    private var commandInProgress = false
    private var hasLaunched = false
    private var scheduledMaintenanceTask: Task<Void, Never>?

    convenience init() {
        self.init(llama: LlamaService(), volumeAccess: VolumeAccessService(), modelDownload: ModelDownloadService())
    }

    init(llama: LlamaService, volumeAccess: VolumeAccessService? = nil, modelDownload: ModelDownloadService? = nil, xpcServices: XPCServiceManager? = nil, osLogStreamService: OSLogStreamService? = nil) {
        self.llama = llama
        let client = volumeAccess?.ingestClient ?? IngestClient()
        self.volumeAccess = volumeAccess ?? VolumeAccessService(ingestClient: client)
        let downloadService = modelDownload ?? ModelDownloadService()
        self.modelDownload = downloadService
        self.ingestService = IngestService(client: self.volumeAccess.ingestClient ?? client, postgres: postgres)
        let xpcMgr = xpcServices ?? XPCServiceManager()
        let osLogSvc = osLogStreamService ?? OSLogStreamService()
        xpcMgr.osLogStreamService = osLogSvc
        self.xpcServices = xpcMgr
        self.osLogStreamService = osLogSvc
        garage = GarageCLIService(postgres: postgres)
        ingest = GarageCLIService(postgres: postgres, commandLabel: "garage ingest")
        backfill = GarageCLIService(postgres: postgres, commandLabel: "garage backfill")
        mcp = GarageMCPService(postgres: postgres)
        grpc = GarageGRPCService(postgres: postgres)

        if let storedEnabled = UserDefaults.standard.object(forKey: Self.scheduledMaintenanceEnabledKey) as? Bool {
            scheduledMaintenanceEnabled = storedEnabled
        } else {
            scheduledMaintenanceEnabled = true
        }
        let storedInterval = UserDefaults.standard.double(
            forKey: Self.scheduledMaintenanceIntervalKey
        )
        scheduledMaintenanceInterval = storedInterval > 0 ? storedInterval : 60 * 60

        // Forward changes from child ObservableObjects to AppState observers
        downloadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        llama.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        postgres.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        mcp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        grpc.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        backfill.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        ingest.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        garage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.volumeAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.ingestService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.xpcServices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.osLogStreamService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        do {
            lmStudioTokenConfigured = try LMStudioTokenStore.load() != nil
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }

        fetchPresetModels()
        Self.shared = self
    }

    func launch() {
        hasLaunched = true
        fetchPresetModels()
        volumeAccess.restoreAndVerifyAccess()
        osLogStreamService.loadAllPersistedLogs()
        xpcServices.startStreamingAllServices()
        Task { await fetchRegisteredSources() }
        Task { await fetchCorpusStats() }
        configureScheduledMaintenance()
        Task { await llama.refreshStatus() }
        Task { await modelDownload.refresh() }
        Task { await xpcServices.refreshAll() }
        guard autoStartPostgres else { return }
        Task { await startPostgres() }
    }

    func startPostgres() async {
        do {
            try await postgres.start()
            if postgres.status == .running {
                // Each daemon starts independently: an MCP failure must not keep the gRPC backend down.
                try? await mcp.start()
                try? await grpc.start()
            }
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
        } catch {
            // Status already reflects .failed(...); nothing else to do here.
        }
    }

    func fetchPresetModels() {
        self.presetModels = GarageConfigLoader.loadModelPresets()
    }

    func fetchRegisteredModels() async {
        fetchPresetModels()
        guard postgres.status == .running else { return }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let models = try postgres.listRegisteredModels()
            self.registeredModels = models
        } catch {
            // Silently ignore or leave models as-is if table not yet migrated
        }
    }

    func fetchRegisteredSources() async {
        isFetchingSources = true
        defer { isFetchingSources = false }

        let configSources = GarageConfigLoader.loadSourcesFromConfig()
        var dbSources: [RegisteredSource] = []
        if postgres.status == .running {
            do {
                dbSources = try postgres.listRegisteredSources()
            } catch {
                // Table might not exist yet or error
            }
        }

        var merged: [String: RegisteredSource] = [:]
        for cs in configSources {
            merged[cs.slug] = cs
        }
        for ds in dbSources {
            if let existing = merged[ds.slug] {
                merged[ds.slug] = RegisteredSource(
                    slug: ds.slug,
                    kind: ds.kind.isEmpty ? existing.kind : ds.kind,
                    root: ds.root.isEmpty ? existing.root : ds.root,
                    corpusClass: ds.corpusClass.isEmpty ? existing.corpusClass : ds.corpusClass,
                    trust: ds.trust.isEmpty ? existing.trust : ds.trust,
                    allowCloudEnrichment: ds.allowCloudEnrichment,
                    enabled: ds.enabled,
                    includeCode: existing.includeCode,
                    origin: .both,
                    documentCount: ds.documentCount,
                    expectedElements: ds.expectedElements
                )
            } else {
                merged[ds.slug] = ds
            }
        }

        self.registeredSources = Array(merged.values).sorted { $0.slug < $1.slug }
    }

    func fetchCorpusStats() async {
        guard postgres.status == .running else {
            var stats = CorpusStats()
            stats.sourcesCount = registeredSources.count
            self.corpusStats = stats
            return
        }
        isFetchingStats = true
        defer { isFetchingStats = false }
        do {
            var stats = try postgres.fetchCorpusStats()
            if stats.sourcesCount == 0 && !registeredSources.isEmpty {
                stats.sourcesCount = registeredSources.count
            }
            self.corpusStats = stats
            if let docCounts = try? postgres.fetchSourceDocumentCounts() {
                self.registeredSources = self.registeredSources.map { source in
                    var updated = source
                    if let count = docCounts[source.slug] {
                        updated.documentCount = count
                    }
                    return updated
                }
            }
        } catch {
            var fallback = self.corpusStats
            if fallback.sourcesCount == 0 {
                fallback.sourcesCount = registeredSources.count
            }
            fallback.lastUpdated = Date()
            self.corpusStats = fallback
        }
    }

    func stopPostgres() async {
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        await mcp.stop()
        await grpc.stop()
        await postgres.stop()
    }

    /// Synchronously terminates all child and daemon processes, CLI runs, and XPC helper services.
    func terminateImmediately() {
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        mcp.terminateImmediately()
        grpc.terminateImmediately()
        postgres.terminateImmediately()
        garage.cancel()
        ingest.cancel()
        backfill.cancel()
        xpcServices.terminateAll()
        XPCServiceManager.stopAnyRunningInstances()
        PostgresService.stopAnyRunningInstance()
    }

    func resetDatabase() async {
        do {
            try await postgres.resetDatabase()
            if postgres.status == .running || postgres.status == .needsMigration {
                try await postgres.applyMigrations()
                await runGarage(["sync"])
                if postgres.status == .running {
                    try? await mcp.start()
                    try? await grpc.start()
                }
                await fetchRegisteredModels()
                await fetchRegisteredSources()
                await fetchCorpusStats()
            }
            lastCommandSucceeded = true
            lastCommandOutput = "Database reset successfully."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to reset database: \(error.localizedDescription)"
        }
    }

    func applyMigrations() async {
        guard postgres.status == .running || postgres.status == .needsMigration else { return }
        isApplyingMigrations = true
        defer { isApplyingMigrations = false }
        do {
            try await postgres.applyMigrations()
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
            if postgres.status == .running {
                if mcp.status == .stopped {
                    try? await mcp.start()
                }
                if grpc.status == .stopped {
                    try? await grpc.start()
                }
            }
            lastCommandSucceeded = true
            lastCommandOutput = "Applied schema migrations successfully."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to apply migrations: \(error.localizedDescription)"
        }
    }

    func checkPendingMigrations() {
        postgres.refreshPendingMigrations()
        if postgres.status == .running {
            Task {
                if mcp.status == .stopped {
                    try? await mcp.start()
                }
                if grpc.status == .stopped {
                    try? await grpc.start()
                }
            }
        }
    }

    @discardableResult
    func copyDatabaseURLToClipboard() -> Bool {
        do {
            let urlString = try postgres.copyStandardConnectionURLToClipboard()
            lastCommandSucceeded = true
            lastCommandOutput = "Copied PostgreSQL connection URL to clipboard: \(urlString)"
            return true
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to copy database connection URL: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func openDatabaseInHandler() -> Bool {
        do {
            let opened = try postgres.openInRegisteredHandler()
            if opened {
                lastCommandSucceeded = true
                lastCommandOutput = "Opened PostgreSQL database URL in registered handler: \(try postgres.standardConnectionURLString())"
            } else {
                lastCommandSucceeded = false
                lastCommandOutput = "No application registered to open postgresql:// URLs."
            }
            return opened
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to open database connection URL: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveLMStudioToken(_ rawToken: String) -> Bool {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            lastCommandSucceeded = false
            lastCommandOutput = "LM Studio API token must not be empty."
            return false
        }
        do {
            try LMStudioTokenStore.save(token)
            lmStudioTokenConfigured = true
            lastCommandSucceeded = true
            lastCommandOutput = "LM Studio API token saved in Keychain."
            return true
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
            return false
        }
    }

    func removeLMStudioToken() {
        do {
            try LMStudioTokenStore.remove()
            lmStudioTokenConfigured = false
            lastCommandSucceeded = true
            lastCommandOutput = "LM Studio API token removed from Keychain."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }
    }

    func backupDatabase(to destination: URL) {
        performDatabaseOperation { try postgres.backupDatabase(to: destination) }
    }

    func restoreDatabase(from source: URL) {
        performDatabaseOperation { try postgres.restoreDatabase(from: source) }
    }

    @discardableResult
    func promptAndSelectRootVolume() -> URL? {
        let url = volumeAccess.promptForRootVolumeSelection()
        if let url = url {
            lastCommandSucceeded = true
            lastCommandOutput = "Granted full volume access for: \(url.path)"
        }
        return url
    }

    @discardableResult
    func promptAndSelectSourceDirectory(slug: String? = nil, suggestedPath: String) -> URL? {
        let url = volumeAccess.promptForSourceDirectoryAccess(slug: slug, suggestedPath: suggestedPath)
        if let url = url {
            lastCommandSucceeded = true
            lastCommandOutput = "Granted access for '\(slug ?? suggestedPath)' at: \(url.path)"
            _ = testVolumeAccess()
        }
        return url
    }

    @discardableResult
    func promptTCCPermission(category: TCCPermissionCategory, sourceSlug: String? = nil, sourcePath: String? = nil) -> Bool {
        let handled = volumeAccess.promptForTCCPermission(category: category, sourceSlug: sourceSlug, sourcePath: sourcePath)
        if handled {
            _ = testVolumeAccess()
        }
        return handled
    }

    func openPrivacySettings(for category: TCCPermissionCategory = .fullDiskAccess) {
        volumeAccess.openPrivacySettings(for: category)
    }

    @discardableResult
    func testVolumeAccess() -> VolumeAccessTestResult {
        let sourceTuples = registeredSources.map { (slug: $0.slug, root: $0.root) }
        let result = volumeAccess.testFullVolumeAccess(sourcePaths: sourceTuples)
        lastCommandSucceeded = result.isAccessible
        lastCommandOutput = result.message
        return result
    }

    func revokeVolumeAccess() {
        volumeAccess.revokeAccess()
        lastCommandSucceeded = true
        lastCommandOutput = "Volume access revoked and saved bookmark cleared."
    }

    #if DEBUG
    func setRegisteredSourcesForTesting(_ sources: [RegisteredSource]) {
        self.registeredSources = sources
    }

    func setRegisteredModelsForTesting(_ models: [RegisteredModel]) {
        self.registeredModels = models
    }

    func setCorpusStatsForTesting(_ stats: CorpusStats) {
        self.corpusStats = stats
    }

    func setIngestingForTesting(_ isIngesting: Bool) {
        self.ingestService.setRunningForTesting(isIngesting)
    }
    #endif

    /// Performs a scan on configured sources to calculate item counts and update expected element totals.
    @discardableResult
    func scanSources(source: String = "*", includeCode: Bool = false) async -> Bool {
        guard postgres.status == .running else { return false }
        guard !isIngesting else {
            logger.info("Scan skipped because ingestion is in progress.")
            return false
        }
        var args = ["scan", "--source", source]
        if includeCode {
            args.append("--include-code")
        }
        let succeeded = await runGarage(args)
        await fetchRegisteredSources()
        await fetchCorpusStats()
        return succeeded
    }

    /// Runs a garage subcommand and captures its combined output for display.
    @discardableResult
    func runGarage(_ arguments: [String]) async -> Bool {
        if arguments.first == "scan" && isIngesting {
            lastCommandSucceeded = false
            lastCommandOutput = "Cannot scan while ingestion is in progress."
            logger.warning("Attempted to run garage scan while ingestion is in progress.")
            return false
        }

        guard !commandInProgress else {
            lastCommandSucceeded = false
            lastCommandOutput = "A garage command is already running."
            return false
        }

        commandInProgress = true
        defer { commandInProgress = false }
        let result = await garage.run(arguments)
        lastCommandOutput = result.lines.map(\.text).joined(separator: "\n")
        lastCommandSucceeded = result.succeeded

        if result.succeeded, let command = arguments.first, Self.maintenanceTriggeringCommands.contains(command) {
            Task { [weak self] in await self?.triggerMaintenanceIfEnabled() }
        }

        return result.succeeded
    }

    /// Runs ingestion in an independent process and log stream.
    @discardableResult
    func runIngest(_ arguments: [String]) async -> Bool {
        let result = await ingest.run(arguments)
        return result.succeeded
    }

    /// Runs ingestion through the configured execution mode (XPC helper or CLI) streaming real-time progress.
    @discardableResult
    func ingestSource(slug: String, options: IngestOptions = .default, mode: IngestExecutionMode? = nil) async -> Bool {
        if slug == "*" {
            return await ingestAllSources(options: options, mode: mode)
        }
        let result = await ingestService.ingest(slug: slug, options: options, mode: mode)
        await fetchRegisteredSources()
        await fetchCorpusStats()
        lastCommandSucceeded = result.succeeded
        lastCommandOutput = result.message ?? (result.succeeded ? "Ingestion completed" : "Ingestion failed")
        return result.succeeded
    }

    /// Ingests all registered sources sequentially, looping over each source and streaming individual progress.
    @discardableResult
    func ingestAllSources(options: IngestOptions = .default, mode: IngestExecutionMode? = nil) async -> Bool {
        await fetchRegisteredSources()
        let sources = registeredSources
        guard !sources.isEmpty else {
            let msg = "No sources registered to ingest."
            logger.warning("\(msg, privacy: .public)")
            return false
        }
        let allSlugs = Set(sources.map(\.slug))
        ingestService.clearProgressBySource()
        ingestService.setPendingSources(allSlugs)
        defer {
            ingestService.clearPendingSources()
        }
        var allSucceeded = true
        for source in sources {
            if ingestService.isCancelling {
                logger.info("ingestAllSources stopped because cancellation was requested.")
                break
            }
            ingestService.markSourceActive(source.slug)
            let sourceOptions = IngestOptions(
                includeCode: options.includeCode || source.includeCode,
                limit: options.limit,
                force: options.force,
                grpcHost: options.grpcHost,
                grpcPort: options.grpcPort,
                extraArguments: options.extraArguments
            )
            let result = await ingestService.ingest(slug: source.slug, options: sourceOptions, mode: mode)
            await fetchRegisteredSources()
            await fetchCorpusStats()
            if !result.succeeded {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Runs ingestion specifically through the XPC service streaming real-time progress to the UI.
    @discardableResult
    func ingestViaXPC(slug: String, options: IngestOptions = .default) async -> Bool {
        await ingestSource(slug: slug, options: options, mode: .xpcService)
    }

    /// Runs embedding backfill in an independent process and log stream.
    @discardableResult
    func runBackfill(_ arguments: [String]) async -> Bool {
        let result = await backfill.run(arguments)
        await fetchCorpusStats()
        await fetchRegisteredModels()
        return result.succeeded
    }

    /// Combines CLI ingest logs and XPC ingestion logs into a single chronologically ordered stream.
    var combinedIngestLogs: [LogLine] {
        (ingest.logs + ingestService.logs).sorted { $0.date < $1.date }
    }

    func clearLogs(for sourceName: String) {
        switch sourceName {
        case "Postgres":
            postgres.clearLogs()
            osLogStreamService.clearLogs(for: .postgres)
        case "garage CLI", "garage":
            garage.clearLogs()
            osLogStreamService.clearLogs(for: .garage)
        case "Ingest", "Ingest XPC", "Ingest (XPC)", "Ingest (CLI)":
            ingest.clearLogs()
            ingestService.clearLogs()
            osLogStreamService.clearLogs(for: .ingest)
        case "Embedding", "Backfill":
            backfill.clearLogs()
            osLogStreamService.clearLogs(for: .embed)
        case "MCP Server":
            mcp.clearLogs()
            osLogStreamService.clearLogs(for: .mcp)
        case "gRPC Server":
            grpc.clearLogs()
            osLogStreamService.clearLogs(for: .grpc)
        case "Llama Service", "Llama XPC":
            llama.clearLogs()
            osLogStreamService.clearLogs(for: .llama)
        case "Model Downloader", "Model Download XPC":
            modelDownload.clearLogs()
            osLogStreamService.clearLogs(for: .modelDownload)
        case "XPC Services", "XPC Service", "XPC":
            xpcServices.clearLogs()
        case "Unified Log", "Unified Logs", "Unified (OSLog)", "OSLog", "System Log":
            osLogStreamService.clearLogs()
        default:
            osLogStreamService.clearLogs()
        }
    }

    /// Performs search using the gRPC server endpoint.
    func search(
        query: String,
        mode: String = "hybrid",
        model: String? = nil,
        limit: Int = 10,
        corpusClasses: [String] = [],
        trustTiers: [String] = [],
        sources: [String] = [],
        author: String? = nil,
        full: Bool = false
    ) async throws -> [SearchResultItem] {
        let response = try await grpc.search(
            query: query,
            mode: mode,
            model: model,
            limit: limit,
            corpusClasses: corpusClasses,
            trustTiers: trustTiers,
            sources: sources,
            author: author,
            full: full
        )
        return response.hits.map { SearchResultItem(hit: $0) }
    }

    /// Lists documents via the gRPC server, optionally filtered by source/class/trust/query.
    func listDocuments(
        source: String? = nil,
        corpusClass: String? = nil,
        trustTier: String? = nil,
        query: String? = nil,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> (items: [DocumentListItem], totalCount: Int) {
        let response = try await grpc.listDocuments(
            source: source,
            corpusClass: corpusClass,
            trustTier: trustTier,
            query: query,
            limit: limit,
            offset: offset
        )
        return (response.documents.map { DocumentListItem(summary: $0) }, Int(response.totalCount))
    }

    /// Fetches a single document's metadata and chunks via the gRPC server.
    func getDocument(documentID: Int64) async throws -> DocumentDetailItem {
        let response = try await grpc.getDocument(documentID: documentID)
        return DocumentDetailItem(response: response)
    }

    private func configureScheduledMaintenance() {
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil

        guard hasLaunched, scheduledMaintenanceEnabled else { return }

        let interval = UInt64(scheduledMaintenanceInterval * 1_000_000_000)
        scheduledMaintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.runScheduledMaintenance()
            }
        }
    }

    var isIngesting: Bool {
        ingestService.isRunning || ingest.isRunning
    }

    var isScanning: Bool {
        garage.isRunning
    }

    func cancelScan() {
        garage.cancel()
    }

    func cancelIngest() async {
        if ingestService.isRunning {
            _ = await ingestService.cancel()
        }
        if ingest.isRunning {
            ingest.cancel()
        }
    }

    private func runScheduledMaintenance() async {
        guard postgres.status == .running, !ingestService.isRunning, !ingest.isRunning, !backfill.isRunning else { return }

        _ = await scanSources()
        let ingestSucceeded = await ingestAllSources(mode: .xpcService)
        let backfillSucceeded = await runBackfill(["backfill"])
        await fetchCorpusStats()
        lastCommandSucceeded = ingestSucceeded && backfillSucceeded
    }

    /// Kicks off ingest + embedding backfill for all sources when the user has enabled
    /// automatic maintenance, e.g. right after a new source or model is registered.
    func triggerMaintenanceIfEnabled() async {
        guard scheduledMaintenanceEnabled else { return }
        await runScheduledMaintenance()
    }

    private func performDatabaseOperation(_ operation: () throws -> Void) {
        do {
            try operation()
            lastCommandSucceeded = true
            lastCommandOutput = "Completed successfully."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }
    }

    // MARK: - Combined Ingest Progress Tracking

    /// Total number of expected documents from prior scan across active / registered sources.
    var combinedIngestTotalExpected: Int {
        // If ingesting a single source and not in a batch run:
        if ingestService.pendingSources.isEmpty,
           let current = ingestService.currentSource,
           current != "*",
           let src = registeredSources.first(where: { $0.slug == current }) {
            if src.expectedElements > 0 {
                return src.expectedElements
            }
            if let latest = ingestService.latestProgress, latest.totalItems > 0 {
                return latest.totalItems
            }
            return 0
        }

        // Multi-source / all sources batch run:
        let totalFromScan = corpusStats.totalExpectedElements > 0
            ? corpusStats.totalExpectedElements
            : registeredSources.reduce(0) { $0 + $1.expectedElements }
        if totalFromScan > 0 {
            return totalFromScan
        }

        // If no prior scan total, sum totalItems from known progress updates
        let totalFromUpdates = registeredSources.reduce(0) { sum, source in
            if let prog = ingestService.progressBySource[source.slug] {
                return sum + prog.totalItems
            }
            return sum
        }
        if totalFromUpdates > 0 {
            return totalFromUpdates
        }

        return ingestService.latestProgress?.totalItems ?? 0
    }

    /// Total number of documents processed (seen / scanned) so far in the current ingestion run.
    var combinedIngestProcessedCount: Int {
        // If single source:
        if ingestService.pendingSources.isEmpty,
           let current = ingestService.currentSource,
           current != "*",
           let src = registeredSources.first(where: { $0.slug == current }) {
            let seen = ingestService.latestProgress?.seen ?? 0
            if src.expectedElements > 0 {
                return min(src.expectedElements, seen)
            }
            return seen
        }

        // Multi-source:
        let totalExpected = combinedIngestTotalExpected
        var totalProcessed = 0

        for source in registeredSources {
            if source.slug == ingestService.currentSource {
                let seen = ingestService.latestProgress?.seen ?? 0
                if source.expectedElements > 0 {
                    totalProcessed += min(source.expectedElements, seen)
                } else {
                    totalProcessed += seen
                }
            } else if let prog = ingestService.progressBySource[source.slug] {
                if source.expectedElements > 0 {
                    totalProcessed += source.expectedElements
                } else if prog.seen > 0 {
                    totalProcessed += prog.seen
                } else {
                    totalProcessed += prog.indexed
                }
            }
        }

        if totalExpected > 0 {
            return min(totalExpected, totalProcessed)
        }
        return totalProcessed
    }

    /// Combined progress fraction from 0.0 to 1.0 based on combined documents from prior scan.
    var combinedIngestProgressFraction: Double {
        let total = combinedIngestTotalExpected
        let processed = combinedIngestProcessedCount
        if total > 0 {
            return min(1.0, max(0.0, Double(processed) / Double(total)))
        }
        if let latest = ingestService.latestProgress {
            return latest.progress
        }
        return 0.0
    }

    /// Formatted percentage string for the combined ingest progress (e.g. "45%").
    var combinedIngestProgressPercent: String {
        let fraction = combinedIngestProgressFraction
        return "\(Int((fraction * 100.0).rounded()))%"
    }

    var combinedIngestIndexedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.indexed
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.indexed
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.indexed
        }
        return count
    }

    var combinedIngestSkippedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.skipped
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.skipped
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.skipped
        }
        return count
    }

    var combinedIngestFailedCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.failed
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.failed
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.failed
        }
        return count
    }

    var combinedIngestPlaceholdersCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.placeholders
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.placeholders
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.placeholders
        }
        return count
    }

    var combinedIngestChunksCount: Int {
        var count = 0
        for source in registeredSources {
            if source.slug == ingestService.currentSource, let latest = ingestService.latestProgress {
                count += latest.chunksWritten
            } else if let prog = ingestService.progressBySource[source.slug] {
                count += prog.chunksWritten
            }
        }
        if count == 0, let latest = ingestService.latestProgress {
            return latest.chunksWritten
        }
        return count
    }

    var combinedIngestItemType: String {
        ingestService.latestProgress?.itemType ?? "documents"
    }

    var combinedIngestTitle: String {
        if ingestService.pendingSources.isEmpty, let current = ingestService.currentSource, current != "*" {
            return current
        }
        if let current = ingestService.currentSource, !current.isEmpty, current != "*" {
            return "Ingesting \(current)"
        }
        return "Ingestion"
    }

    var combinedIngestStatusMessage: String {
        let total = combinedIngestTotalExpected
        let processed = combinedIngestProcessedCount
        let indexed = combinedIngestIndexedCount
        let skipped = combinedIngestSkippedCount
        let itemType = combinedIngestItemType
        if total > 0 {
            return "\(processed) of \(total) \(itemType) (\(indexed) indexed, \(skipped) skipped)"
        }
        if let msg = ingestService.latestProgress?.message, !msg.isEmpty {
            return msg
        }
        return "\(indexed) indexed, \(skipped) skipped"
    }

    var statusSummary: String {
        switch postgres.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running on port \(postgres.port)"
        case .stopping: "Stopping…"
        case .needsMigration: "Needs Migration"
        case .failed(let message): "Failed: \(message)"
        }
    }

    // MARK: - Single Source Ingest Progress Tracking

    /// Total number of expected documents for a specific source (from prior scan or progress updates).
    func sourceTotalExpected(for sourceSlug: String) -> Int {
        if let src = registeredSources.first(where: { $0.slug == sourceSlug }), src.expectedElements > 0 {
            return src.expectedElements
        }
        if let prog = ingestService.progressBySource[sourceSlug], prog.totalItems > 0 {
            return prog.totalItems
        }
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress, latest.totalItems > 0 {
            return latest.totalItems
        }
        return 0
    }

    /// Number of documents processed (seen / scanned) for a specific source.
    func sourceProcessedCount(for sourceSlug: String) -> Int {
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress {
            let total = sourceTotalExpected(for: sourceSlug)
            if total > 0 {
                return min(total, latest.seen)
            }
            return latest.seen
        }
        if let prog = ingestService.progressBySource[sourceSlug] {
            if let src = registeredSources.first(where: { $0.slug == sourceSlug }), src.expectedElements > 0 {
                return src.expectedElements
            }
            return prog.seen > 0 ? prog.seen : prog.indexed
        }
        if let src = registeredSources.first(where: { $0.slug == sourceSlug }) {
            return src.documentCount
        }
        return 0
    }

    /// Progress fraction from 0.0 to 1.0 for a specific single source based on its items.
    func sourceProgressFraction(for sourceSlug: String) -> Double {
        let total = sourceTotalExpected(for: sourceSlug)
        let processed = sourceProcessedCount(for: sourceSlug)
        if total > 0 {
            return min(1.0, max(0.0, Double(processed) / Double(total)))
        }
        if ingestService.currentSource == sourceSlug, let latest = ingestService.latestProgress {
            return latest.progress
        }
        if let prog = ingestService.progressBySource[sourceSlug] {
            return prog.progress
        }
        return 0.0
    }

    /// Formatted percentage string for a specific single source (e.g. "50%").
    func sourceProgressPercent(for sourceSlug: String) -> String {
        let fraction = sourceProgressFraction(for: sourceSlug)
        return "\(Int((fraction * 100.0).rounded()))%"
    }

    var statusColor: Color {
        switch postgres.status {
        case .running: .green
        case .starting, .stopping, .needsMigration: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }
}
