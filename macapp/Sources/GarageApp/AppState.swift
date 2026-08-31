import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let scheduledMaintenanceEnabledKey = "scheduledMaintenanceEnabled"
    private static let scheduledMaintenanceIntervalKey = "scheduledMaintenanceInterval"

    let postgres = PostgresService()
    let garage: GarageCLIService
    let ingest: GarageCLIService
    let backfill: GarageCLIService
    let mcp: GarageMCPService

    /// Output of the most recent manual or scheduled `garage` command,
    /// separate from the rolling activity log.
    @Published var lastCommandOutput: String = ""
    @Published var lastCommandSucceeded: Bool?
    @Published var autoStartPostgres = true
    @Published private(set) var lmStudioTokenConfigured = false
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

    init() {
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
        do {
            lmStudioTokenConfigured = try LMStudioTokenStore.load() != nil
        } catch {
            lastCommandSucceeded = false
            lastCommandOutput = error.localizedDescription
        }
    }

    func launch() {
        hasLaunched = true
        configureScheduledMaintenance()
        guard autoStartPostgres else { return }
        Task { await startPostgres() }
    }

    func startPostgres() async {
        do {
            try await postgres.start()
            try await mcp.start()
        } catch {
            // Status already reflects .failed(...); nothing else to do here.
        }
    }

    func stopPostgres() async {
        await mcp.stop()
        await postgres.stop()
    }

    func resetDatabase() {
        performDatabaseOperation { try postgres.resetDatabase() }
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
