import AppKit
import Foundation
import SwiftUI
import Combine
import OSLog
import GarageUpdater
import IngestClient
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "AppState")

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?
    private static let scheduledMaintenanceEnabledKey = "scheduledMaintenanceEnabled"
    private static let scheduledMaintenanceIntervalKey = "scheduledMaintenanceInterval"

    let postgres = PostgresService()
    /// General operations (sources, models, schema, settings), one at a time.
    let garage: OperationRunner
    /// Embedding backfill and fact distillation run on their own runners so a long
    /// job never blocks an ordinary operation.
    let backfill: OperationRunner
    let enrichFacts: OperationRunner
    let mcp: GarageMCPService
    let grpc: GarageGRPCService
    let llama: LlamaService
    let modelDownload: ModelDownloadService
    let volumeAccess: VolumeAccessService
    /// Sparkle front end. Inert in App Store builds, which update
    /// through the App Store rather than embedding Sparkle at all.
    let updater = UpdaterService.shared
    @Published var ingestService: IngestService
    let xpcServices: XPCServiceManager
    @Published var osLogStreamService: OSLogStreamService
    private var cancellables = Set<AnyCancellable>()

    /// Output of the most recent manual or scheduled operation,
    /// separate from the rolling activity log.
    @Published var lastCommandOutput: String = ""
    @Published var lastCommandSucceeded: Bool?
    @Published var autoStartPostgres = true
    @Published private(set) var lmStudioTokenConfigured = false
    @Published private(set) var presetModels: [ModelPresetEntry] = []
    /// Generative presets (models.json `fact_distil`) offered for fact distillation / `rag_ask`.
    @Published private(set) var factDistilPresets: [ModelPresetEntry] = []
    /// The `facts` section of garage.json: which model answers `enrich-facts` and `rag_ask`.
    @Published private(set) var factsModel: String = GarageConfigLoader.defaultFactsModel
    @Published private(set) var factsProvider: String = GarageConfigLoader.defaultFactsProvider
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
    /// True from the moment "Reset Database" starts stopping services until this instance quits.
    @Published private(set) var isResettingDatabase = false
    private var hasLaunched = false
    private var hasTerminated = false
    /// Set once "Reset Database" has asked a new instance to start. From then on this instance's
    /// services are already stopped, and the Postgres pid file and XPC service names belong to the new
    /// instance, so quitting must not run the usual shutdown (which stops both by pid file and name).
    private(set) var hasHandedOffToRelaunch = false
    private var scheduledMaintenanceTask: Task<Void, Never>?
    private var pendingMaintenanceTask: Task<Void, Never>?

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
        garage = OperationRunner(label: "garage")
        backfill = OperationRunner(label: "garage backfill")
        enrichFacts = OperationRunner(label: "garage enrich-facts")
        let grpcService = GarageGRPCService(postgres: postgres)
        let mcpService = GarageMCPService(postgres: postgres)
        // Client registration (McpInstall) goes over gRPC.
        mcpService.grpc = grpcService
        mcp = mcpService
        grpc = grpcService

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
        enrichFacts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        garage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.volumeAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.ingestService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.xpcServices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.osLogStreamService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

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
        guard !hasLaunched else { return }
        hasLaunched = true
        let arguments = CommandLine.arguments
        guard arguments.contains(GarageAppLaunch.databaseResetArgument) else {
            launchServices(startsPostgres: autoStartPostgres)
            return
        }
        lastCommandOutput = "Creating a new database…"
        Task {
            // The instance that deleted the database quits right after launching this one, and its
            // quit path stops Postgres by pid file and XPC services by executable name. Start
            // nothing of our own until it is gone.
            if let parent = Self.databaseResetParent(in: arguments) {
                await Self.waitForExit(of: parent, timeout: 30)
            }
            launchServices(startsPostgres: false)
            await startPostgres()
            await finishDatabaseReset()
        }
    }

    /// The pid after `--after-database-reset`, when this instance was launched by a reset.
    nonisolated static func databaseResetParent(in arguments: [String]) -> pid_t? {
        guard let flag = arguments.firstIndex(of: GarageAppLaunch.databaseResetArgument),
              flag + 1 < arguments.count,
              let pid = pid_t(arguments[flag + 1]), pid > 0 else {
            return nil
        }
        return pid
    }

    /// Returns once `pid` has exited, or after `timeout` seconds.
    nonisolated static func waitForExit(of pid: pid_t, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, kill(pid, 0) == 0 || errno == EPERM {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func launchServices(startsPostgres: Bool) {
        // Before anything reads the data folder's contents or starts Postgres / an XPC service.
        GarageDataMigration.runAtLaunch()
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
        guard startsPostgres else { return }
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
        self.factDistilPresets = GarageConfigLoader.loadFactDistilPresets()
        fetchFactsSettings()
    }

    /// Re-reads the `facts` section of garage.json.
    func fetchFactsSettings() {
        let facts = GarageConfigLoader.loadFactsSettings()
        self.factsModel = facts.model
        self.factsProvider = facts.provider
    }

    /// Points `enrich-facts` / `rag_ask` at a model: sets `facts.model`, then `facts.provider`.
    @discardableResult
    func setFactsModel(_ slug: String, provider: String = GarageConfigLoader.defaultFactsProvider) async -> Bool {
        let succeeded = await runOperation { grpc in
            let model = try await grpc.setSetting("facts.model", to: slug)
            let chosen = try await grpc.setSetting("facts.provider", to: provider)
            return [model.summary, chosen.summary].joined(separator: "\n")
        }
        fetchFactsSettings()
        return succeeded
    }

    func fetchRegisteredModels() async {
        fetchPresetModels()
        guard postgres.status == .running else { return }
        isFetchingModels = true
        defer { isFetchingModels = false }
        do {
            let models = try await postgres.listRegisteredModels()
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
                dbSources = try await postgres.listRegisteredSources()
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
            var stats = try await postgres.fetchCorpusStats()
            if stats.sourcesCount == 0 && !registeredSources.isEmpty {
                stats.sourcesCount = registeredSources.count
            }
            self.corpusStats = stats
            let docCounts = stats.sourceDocumentCounts
            if !docCounts.isEmpty {
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
        await mcp.stop()
        await grpc.stop()
        await postgres.stop()
    }

    /// Synchronously terminates all child and daemon processes, CLI runs, and XPC helper services.
    /// Idempotent: every quit path (applicationShouldTerminate, applicationWillTerminate) calls it once.
    func terminateImmediately() {
        guard !hasTerminated, !hasHandedOffToRelaunch else { return }
        hasTerminated = true
        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = nil
        mcp.terminateImmediately()
        grpc.terminateImmediately()
        // postgres.terminateImmediately() already runs PostgresService.stopAnyRunningInstance().
        postgres.terminateImmediately()
        garage.cancel()
        backfill.cancel()
        enrichFacts.cancel()
        // xpcServices.terminateAll() already runs XPCServiceManager.stopAnyRunningInstances().
        xpcServices.terminateAll()
    }

    /// "Reset Database": stops every service, deletes the Postgres cluster, and relaunches the app,
    /// which creates a new, empty database (`finishDatabaseReset`). Only what Garage built goes: the
    /// sources' own files, downloaded model files, logs, garage.json and the Keychain password stay.
    func resetDatabaseAndRelaunch() async {
        guard !isResettingDatabase else { return }
        isResettingDatabase = true
        lastCommandOutput = "Stopping Garage's services…"

        scheduledMaintenanceTask?.cancel()
        scheduledMaintenanceTask = nil
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = nil
        garage.cancel()
        backfill.cancel()
        enrichFacts.cancel()
        await mcp.stop()
        await grpc.stop()
        await postgres.stop()
        // Anything still holding pgdata: an orphaned postmaster from an earlier run.
        await PostgresService.stopAnyRunningInstance()
        xpcServices.terminateAll()

        do {
            try await postgres.deleteClusterForReset()
        } catch {
            isResettingDatabase = false
            lastCommandSucceeded = false
            lastCommandOutput = "Reset stopped: \(error.localizedDescription) Restarting the services."
            xpcServices.startStreamingAllServices()
            configureScheduledMaintenance()
            await startPostgres()
            return
        }
        // Never relaunch the test host.
        guard !isRunningInTestEnvironment else {
            isResettingDatabase = false
            return
        }
        lastCommandOutput = "Database deleted. Relaunching Garage to create a new one…"
        relaunchAfterDatabaseReset()
    }

    private func relaunchAfterDatabaseReset() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [GarageAppLaunch.databaseResetArgument, String(getpid())]
        // Before the new instance can start anything: a quit from here on must leave its services alone.
        markHandedOffToRelaunch()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let failure else {
                    Self.terminateFromRunLoop()
                    return
                }
                // No second instance: create the new database in this one instead.
                logger.error("Relaunch after reset failed: \(failure, privacy: .public)")
                self.hasHandedOffToRelaunch = false
                self.isResettingDatabase = false
                await self.startPostgres()
                await self.finishDatabaseReset()
            }
        }
    }

    func markHandedOffToRelaunch() {
        hasHandedOffToRelaunch = true
    }

    /// `NSApp.terminate` from the run loop rather than from inside a main-actor job. Called from a
    /// job, AppKit's wait for `reply(toApplicationShouldTerminate:)` runs a nested event loop inside
    /// that job, and since the main queue is serial, any reply scheduled as another main-actor job
    /// never runs: the app hangs in `terminate:` until it is killed.
    private static func terminateFromRunLoop() {
        RunLoop.main.perform {
            NSApp.terminate(nil)
        }
    }

    /// Second half of a reset, once Postgres has initialized a new cluster: apply the schema,
    /// start the gRPC and MCP services, and register the sources garage.json declares again.
    func finishDatabaseReset() async {
        do {
            if postgres.status == .needsMigration {
                try await postgres.applyMigrations()
            }
            guard postgres.status == .running else {
                throw PostgresError.other("Postgres did not start with the new database; see the Database page.")
            }
            try? await grpc.start()
            try? await mcp.start()
            let synced = await runOperation { try await $0.syncSources().message }
            await fetchRegisteredModels()
            await fetchRegisteredSources()
            await fetchCorpusStats()
            lastCommandSucceeded = synced
            lastCommandOutput = synced
                ? Self.databaseResetMessage(registeredSourceCount: registeredSources.count)
                : "Database reset: a new database was created, but registering the sources from garage.json "
                    + "failed: \(lastCommandOutput)"
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Database reset: the new database could not be set up: \(error.localizedDescription)"
        }
    }

    nonisolated static func databaseResetMessage(registeredSourceCount: Int) -> String {
        let sources = switch registeredSourceCount {
        case 0: "garage.json declares no sources, so none are registered; add them on the Sources page."
        case 1: "The 1 source in garage.json was registered again."
        default: "The \(registeredSourceCount) sources in garage.json were registered again."
        }
        return "Database reset: a new, empty database was created. \(sources) Register your embedding models "
            + "on the Models page, then run ingest to rebuild the index."
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
        Task {
            await postgres.refreshPendingMigrations()
            guard postgres.status == .running else { return }
            if mcp.status == .stopped {
                try? await mcp.start()
            }
            if grpc.status == .stopped {
                try? await grpc.start()
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
        Task {
            await performDatabaseOperation { try await postgres.backupDatabase(to: destination) }
        }
    }

    func restoreDatabase(from source: URL) {
        Task {
            await performDatabaseOperation { try await postgres.restoreDatabase(from: source) }
        }
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
        guard !isIngesting else {
            lastCommandSucceeded = false
            lastCommandOutput = "Cannot scan while ingestion is in progress."
            logger.info("Scan skipped because ingestion is in progress.")
            return false
        }
        guard postgres.status == .running else { return false }
        let succeeded = await runOperation { try await $0.scan(source: source, includeCode: includeCode).message }
        await fetchRegisteredSources()
        await fetchCorpusStats()
        return succeeded
    }

    /// Runs one operation over gRPC on the general runner and shows what it reports.
    /// `triggersMaintenance` schedules ingest + backfill afterwards (a new source or
    /// model has nothing indexed yet) when automatic maintenance is enabled.
    @discardableResult
    func runOperation(
        triggersMaintenance: Bool = false,
        _ operation: @escaping @MainActor (GarageGRPCService) async throws -> String
    ) async -> Bool {
        guard !commandInProgress else {
            lastCommandSucceeded = false
            lastCommandOutput = "A garage command is already running."
            return false
        }

        commandInProgress = true
        defer { commandInProgress = false }
        let grpc = self.grpc
        let result = await garage.run { _ in try await operation(grpc) }
        lastCommandOutput = result.output
        lastCommandSucceeded = result.succeeded

        if result.succeeded, triggersMaintenance {
            scheduleDebouncedMaintenanceTrigger()
        }

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
                grpcPort: options.grpcPort
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

    /// Embeds pending chunks for `model` (nil = every registered model) on the backfill
    /// runner, logging each progress step the server streams back.
    @discardableResult
    func runBackfill(model: String? = nil) async -> Bool {
        let grpc = self.grpc
        let result = await backfill.run { runner in
            _ = try await grpc.backfill(model: model) { status in
                if !status.message.isEmpty {
                    runner.appendLog(status.message)
                }
            }
            return ""
        }
        await fetchCorpusStats()
        await fetchRegisteredModels()
        return result.succeeded
    }

    /// Distills documents into facts ("glean facts") on the enrich-facts runner: every
    /// document of `source`, or just `documentID` when given.
    @discardableResult
    func runEnrichFacts(source: String = "*", documentID: Int64? = nil) async -> Bool {
        let grpc = self.grpc
        let result = await enrichFacts.run { runner in
            let finished = try await grpc.enrichFacts(source: source, documentID: documentID) { status in
                // The summary is logged once, as the operation's result.
                if status.phase != "finished", !status.message.isEmpty {
                    runner.appendLog(status.message, stream: status.error.isEmpty ? .stdout : .stderr)
                }
            }
            return finished?.message ?? ""
        }
        return result.succeeded
    }

    /// XPC ingestion logs as a chronologically ordered stream.
    var combinedIngestLogs: [LogLine] {
        ingestService.logs.sorted { $0.date < $1.date }
    }

    func clearLogs(for sourceName: String) {
        switch sourceName {
        case "Postgres":
            postgres.clearLogs()
            osLogStreamService.clearLogs(for: .postgres)
        case "garage CLI", "garage", "App":
            garage.clearLogs()
            osLogStreamService.clearLogs(for: .garage)
        case "Ingest", "Ingest XPC", "Ingest (XPC)", "Ingest (CLI)":
            ingestService.clearLogs()
            osLogStreamService.clearLogs(for: .ingest)
        case "Embedding", "Backfill", "Embed":
            backfill.clearLogs()
            osLogStreamService.clearLogs(for: .embed)
        case "Enrich Facts", "garage enrich-facts":
            enrichFacts.clearLogs()
        case "MCP Server":
            mcp.clearLogs()
            osLogStreamService.clearLogs(for: .mcp)
        case "gRPC Server":
            grpc.clearLogs()
            osLogStreamService.clearLogs(for: .grpc)
        case "Llama Service", "Llama XPC", "LLaMa":
            llama.clearLogs()
            osLogStreamService.clearLogs(for: .llama)
        case "Model Downloader", "Model Download XPC", "Downloader":
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
        ingestService.isRunning
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
    }

    private func runScheduledMaintenance() async {
        guard postgres.status == .running, !ingestService.isRunning, !backfill.isRunning else { return }

        _ = await scanSources()
        let ingestSucceeded = await ingestAllSources(mode: .xpcService)
        let backfillSucceeded = await runBackfill()
        await fetchCorpusStats()
        lastCommandSucceeded = ingestSucceeded && backfillSucceeded
    }

    /// Kicks off ingest + embedding backfill for all sources when the user has enabled
    /// automatic maintenance, e.g. right after a new source or model is registered.
    func triggerMaintenanceIfEnabled() async {
        guard scheduledMaintenanceEnabled else { return }
        await runScheduledMaintenance()
    }

    /// Debounces `triggerMaintenanceIfEnabled()` so a rapid burst of add-source/
    /// register-model calls (e.g. "Add All") coalesces into a single run that
    /// starts once the burst settles, rather than each add racing `runOperation`'s
    /// `commandInProgress` guard against the scan/ingest the previous add kicked off.
    private func scheduleDebouncedMaintenanceTrigger() {
        pendingMaintenanceTask?.cancel()
        pendingMaintenanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.triggerMaintenanceIfEnabled()
        }
    }

    private func performDatabaseOperation(_ operation: () async throws -> Void) async {
        do {
            try await operation()
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
        if ingestService.runSources.count <= 1,
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
        if ingestService.runSources.count <= 1,
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
        if ingestService.runSources.count <= 1, let current = ingestService.currentSource, current != "*" {
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
