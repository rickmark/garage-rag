import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let postgres = PostgresService()
    let garage: GarageCLIService

    /// Output of the most recently run one-off `garage` command, shown in
    /// whichever tab triggered it (separate from the rolling activity log).
    @Published var lastCommandOutput: String = ""
    @Published var lastCommandSucceeded: Bool?
    @Published var autoStartPostgres = true

    init() {
        garage = GarageCLIService(postgres: postgres)
    }

    func launch() {
        guard autoStartPostgres else { return }
        Task { await startPostgres() }
    }

    func startPostgres() async {
        do {
            try await postgres.start()
        } catch {
            // Status already reflects .failed(...); nothing else to do here.
        }
    }

    func stopPostgres() async {
        await postgres.stop()
    }

    /// Runs a garage subcommand and captures its combined output for display.
    @discardableResult
    func runGarage(_ arguments: [String]) async -> Bool {
        let result = await garage.run(arguments)
        lastCommandOutput = result.lines.map(\.text).joined(separator: "\n")
        lastCommandSucceeded = result.succeeded
        return result.succeeded
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
