import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    private static let scheduledMaintenanceEnabledKey = "scheduledMaintenanceEnabled"
    private static let scheduledMaintenanceIntervalKey = "scheduledMaintenanceInterval"

    let postgres = PostgresService()
    let garage: GarageCLIService
    let ingest: GarageCLIService
    let backfill: GarageCLIService
    let mcp: GarageMCPService
    let llama: LlamaService
    let modelDownload: ModelDownloadService
    let volumeAccess: VolumeAccessService
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
    @Published private(set) var registeredSources: [RegisteredSource] = []
    @Published private(set) var isFetchingSources = false
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

    init(llama: LlamaService, volumeAccess: VolumeAccessService? = nil, modelDownload: ModelDownloadService? = nil) {
        self.llama = llama
        self.volumeAccess = volumeAccess ?? VolumeAccessService()
        let downloadService = modelDownload ?? ModelDownloadService()
        self.modelDownload = downloadService
        garage = GarageCLIService(postgres: postgres)
        ingest = GarageCLIService(postgres: postgres, commandLabel: "garage ingest")
        backfill = GarageCLIService(postgres: postgres, commandLabel: "garage backfill")
        mcp = GarageMCPService(postgres: postgres)

        scheduledMaintenanceEnabled = UserDefaults.standard.bool(
            forKey: Self.scheduledMaintenanceEnabledKey
        )
        let storedInterval = UserDefaults.standard.double(
            forKey: Self.scheduledMaintenanceIntervalKey
        )
        scheduledMaintenanceInterval = storedInterval > 0 ? storedInterval : 60 * 60

        // Forward changes from child ObservableObjects to AppState observers
        downloadService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        llama.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        postgres.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        backfill.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        ingest.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        garage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        self.volumeAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        do {
            lmStudioTokenConfigured = try LMStudioTokenStore.load() != nil
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }

        fetchPresetModels()
    }

    func launch() {
        hasLaunched = true
        fetchPresetModels()
        volumeAccess.restoreAndVerifyAccess()
        Task { await fetchRegisteredSources() }
        configureScheduledMaintenance()
        Task { await llama.refreshStatus() }
        Task { await modelDownload.refresh() }
        guard autoStartPostgres else { return }
        Task { await startPostgres() }
    }

    func startPostgres() async {
        do {
            try await postgres.start()
            try await mcp.start()
            await fetchRegisteredModels()
            await fetchRegisteredSources()
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
                    origin: .both
                )
            } else {
                merged[ds.slug] = ds
            }
        }

        self.registeredSources = Array(merged.values).sorted { $0.slug < $1.slug }
    }

    func stopPostgres() async {
        await mcp.stop()
        await postgres.stop()
    }

    func resetDatabase() async {
        do {
            try await postgres.resetDatabase()
            if postgres.status == .running {
                try? await mcp.start()
                await fetchRegisteredModels()
                await fetchRegisteredSources()
            }
            lastCommandSucceeded = true
            lastCommandOutput = "Database reset successfully."
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = "Failed to reset database: \(error.localizedDescription)"
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

    /// Runs a garage subcommand and captures its combined output for display.
    @discardableResult
    func runGarage(_ arguments: [String]) async -> Bool {
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
        return result.succeeded
    }

    /// Runs ingestion in an independent process and log stream.
    @discardableResult
    func runIngest(_ arguments: [String]) async -> Bool {
        let result = await ingest.run(arguments)
        return result.succeeded
    }

    /// Runs embedding backfill in an independent process and log stream.
    @discardableResult
    func runBackfill(_ arguments: [String]) async -> Bool {
        let result = await backfill.run(arguments)
        return result.succeeded
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

    private func runScheduledMaintenance() async {
        guard postgres.status == .running, !ingest.isRunning, !backfill.isRunning else { return }

        let ingestSucceeded = await runIngest(["ingest", "--source", "*"])
        let backfillSucceeded = await runBackfill(["backfill"])
        lastCommandSucceeded = ingestSucceeded && backfillSucceeded
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

    var statusSummary: String {
        switch postgres.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running on port \(postgres.port)"
        case .stopping: "Stopping…"
        case .failed(let message): "Failed: \(message)"
        }
    }

    var statusColor: Color {
        switch postgres.status {
        case .running: .green
        case .starting, .stopping: .yellow
        case .stopped: .secondary
        case .failed: .red
        }
    }
}
