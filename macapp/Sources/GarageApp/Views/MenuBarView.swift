import GarageUpdater
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(appState.statusColor)
                    .frame(width: 8, height: 8)
                Text("Postgres: \(appState.statusSummary)")
                    .font(.system(size: 12, weight: .medium))
            }

            Divider()

            HStack(spacing: 8) {
                Button(startStopTitle) {
                    Task {
                        if appState.postgres.status == .running {
                            await appState.stopPostgres()
                        } else {
                            await appState.startPostgres()
                        }
                    }
                }
                .disabled(isTransitioning)

                Button("Open Garage") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title == "Garage" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }

            Divider()

            if appState.ingestService.isRunning, let progress = appState.ingestService.latestProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(progress.source.isEmpty ? "Ingesting…" : "Ingesting \(progress.source)")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text(appState.combinedIngestProgressPercent)
                            .font(.system(size: 11, weight: .bold).monospaced())
                            .foregroundStyle(.blue)
                    }
                    if let cur = progress.currentItem, !cur.isEmpty {
                        Text(cur)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(6)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(appState.ingestService.isCancelling ? "Cancelling ingest…" : "Cancel ingestion") {
                    Task { await appState.cancelIngest() }
                }
                .disabled(appState.ingestService.isCancelling)
            } else if appState.isScanning {
                Button("Cancel scan") {
                    appState.cancelScan()
                }
            } else {
                Button("Ingest now") {
                    Task { await appState.ingestAllSources() }
                }
                .disabled(appState.postgres.status != .running || appState.isIngesting || appState.isScanning)
            }

            Divider()

            CheckForUpdatesButton(updater: appState.updater)

            Button("About & Support…") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.title == "Garage" {
                    window.makeKeyAndOrderFront(nil)
                }
                NotificationCenter.default.post(name: .garageShowSplash, object: nil)
            }

            Button("Quit Garage") {
                AppDelegate.quit()
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var startStopTitle: String {
        appState.postgres.status == .running ? "Stop" : "Start"
    }

    private var isTransitioning: Bool {
        appState.postgres.status == .starting || appState.postgres.status == .stopping
    }
}
