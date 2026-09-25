import SwiftUI

/// What the menu bar item says about the app at a glance: the icon, the text beside it and the
/// headline at the top of its popover. Worked out from plain values so it can be tested without
/// an `AppState`; `init(appState:)` reads them from the live one.
struct MenuBarStatus: Equatable {
    enum Activity: Equatable {
        case idle
        case scanning
        /// `fraction` is nil until the ingest reports how far it has got.
        case ingesting(source: String, fraction: Double?)
        case embedding
        case distilling
    }

    enum Database: Equatable {
        case stopped
        case starting
        case stopping
        case running
        case needsMigration
        case failed(String)
    }

    var database: Database
    var activity: Activity

    init(database: Database, activity: Activity) {
        self.database = database
        self.activity = activity
    }

    @MainActor
    init(appState: AppState) {
        switch appState.postgres.status {
        case .stopped: database = .stopped
        case .starting: database = .starting
        case .stopping: database = .stopping
        case .running: database = .running
        case .needsMigration: database = .needsMigration
        case .failed(let message): database = .failed(message)
        }

        if appState.ingestService.isRunning {
            let source = appState.ingestService.latestProgress?.source ?? ""
            let fraction = appState.ingestService.latestProgress == nil ? nil : appState.combinedIngestProgressFraction
            activity = .ingesting(source: source, fraction: fraction)
        } else if appState.isScanning {
            activity = .scanning
        } else if appState.backfill.isRunning {
            activity = .embedding
        } else if appState.enrichFacts.isRunning {
            activity = .distilling
        } else {
            activity = .idle
        }
    }

    /// Something the user has to look at: the database failed or waits on a migration.
    var needsAttention: Bool {
        switch database {
        case .failed, .needsMigration: true
        default: false
        }
    }

    var isBusy: Bool { activity != .idle }

    /// The menu bar icon. It keeps the app's cylinder in every normal state, fills it while work
    /// runs, and swaps to a warning only when something needs the user.
    var symbol: String {
        if needsAttention { return "exclamationmark.triangle" }
        switch database {
        case .stopped, .stopping: return "cylinder"
        case .starting: return "cylinder.split.1x2"
        default: break
        }
        return isBusy ? "cylinder.split.1x2.fill" : "cylinder.split.1x2"
    }

    /// Short text beside the icon, only while an ingest reports its progress.
    var menuBarText: String? {
        guard case .ingesting(_, let fraction?) = activity else { return nil }
        return Self.percent(fraction)
    }

    /// The popover's status line under "Garage".
    var headline: String {
        switch database {
        case .stopped: return "Database stopped"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .needsMigration: return "Database needs a migration"
        case .failed: return "Database failed to start"
        case .running: break
        }
        switch activity {
        case .idle: return "Ready"
        case .scanning: return "Scanning sources…"
        case .ingesting(let source, _): return source.isEmpty ? "Ingesting…" : "Ingesting \(source)…"
        case .embedding: return "Embedding chunks…"
        case .distilling: return "Distilling facts…"
        }
    }

    var tint: Color {
        switch database {
        case .running: isBusy ? .blue : .green
        case .starting, .stopping: .yellow
        case .needsMigration: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    /// The accessibility label for the icon, which otherwise reads as a bare symbol name.
    var accessibilityLabel: String {
        "Garage, \(headline)"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}
