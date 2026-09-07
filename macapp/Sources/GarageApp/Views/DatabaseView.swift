import SwiftUI
import AppKit

@MainActor
struct DatabaseView: View {
    @EnvironmentObject var appState: AppState
    @State private var initRunning = false
    @State private var statsRunning = false
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Postgres") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(appState.statusColor).frame(width: 10, height: 10)
                            Text(appState.statusSummary)
                            Spacer()
                            Button("Start") { Task { await appState.startPostgres() } }
                                .disabled(appState.postgres.status == .running || appState.postgres.status == .starting)
                            Button("Stop") { Task { await appState.stopPostgres() } }
                                .disabled(appState.postgres.status != .running)
                        }
                        LabeledContent("Data directory", value: Paths.pgDataDir.path)
                        LabeledContent("Port", value: String(appState.postgres.port))
                        LabeledContent("Database", value: appState.postgres.databaseName)
                        LabeledContent("Bundled binaries", value: Paths.isPackaged ? "yes (vendored)" : "no (using Homebrew install for development)")
                        LabeledContent("Connection URL") {
                            HStack(spacing: 8) {
                                if let url = try? appState.postgres.standardConnectionURL() {
                                    Text(url.absoluteString)
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Button("Open with Registered Handler") {
                                        appState.openDatabaseInHandler()
                                    }
                                } else {
                                    Text("Unavailable")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Database management") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Backups use PostgreSQL's portable custom dump format.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Back Up…") { chooseBackupDestination() }
                            Button("Restore…") { chooseBackupSource() }
                            Button("Reset Database…") { showResetConfirmation = true }
                                .tint(.red)
                        }
                        .disabled(appState.postgres.status != .running)
                    }
                    .padding(8)
                }

                GroupBox("Schema & Statistics") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Initialize schema (garage init-db)") {
                                Task {
                                    initRunning = true
                                    await appState.runGarage(
                                        ["init-db", "--schema-dir", Paths.schemaDir.path]
                                    )
                                    initRunning = false
                                }
                            }
                            .disabled(appState.postgres.status != .running || initRunning)

                            Button("Show stats (garage stats)") {
                                Task {
                                    statsRunning = true
                                    await appState.runGarage(["stats"])
                                    statsRunning = false
                                }
                            }
                            .disabled(appState.postgres.status != .running || statsRunning)

                            if initRunning || statsRunning {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                if !appState.lastCommandOutput.isEmpty {
                    GroupBox("Last command output") {
                        ScrollView {
                            Text(appState.lastCommandOutput)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 260)
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Database")
        .alert("Reset Garage database?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Database", role: .destructive) {
                appState.resetDatabase()
            }
        } message: {
            Text("This permanently deletes all Garage schemas, sources, and indexed data. The Postgres cluster and its Keychain password are kept.")
        }
    }

    private func chooseBackupDestination() {
        let panel = NSSavePanel()
        panel.title = "Back Up Garage Database"
        panel.nameFieldStringValue = "garage-rag-\(backupTimestamp()).dump"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        appState.backupDatabase(to: destination)
    }

    private func chooseBackupSource() {
        let panel = NSOpenPanel()
        panel.title = "Restore Garage Database"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let source = panel.url else { return }
        appState.restoreDatabase(from: source)
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
