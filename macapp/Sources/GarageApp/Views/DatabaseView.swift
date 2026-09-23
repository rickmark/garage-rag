import SwiftUI
import AppKit

@MainActor
struct DatabaseView: View {
    @EnvironmentObject var appState: AppState
    @State private var initRunning = false
    @State private var statsRunning = false
    @State private var showResetConfirmation = false

    var isPostgresActive: Bool {
        appState.postgres.status == .running || appState.postgres.status == .needsMigration
    }

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
                                .disabled(isPostgresActive || appState.postgres.status == .starting)
                            Button("Stop") { Task { await appState.stopPostgres() } }
                                .disabled(!isPostgresActive)
                        }
                        LabeledContent("Data directory", value: Paths.displayPath(of: Paths.pgDataDir))
                        LabeledContent("Port", value: String(appState.postgres.port))
                        LabeledContent("Database", value: appState.postgres.databaseName)
                        LabeledContent("Bundled binaries", value: Paths.isPackaged ? "yes (vendored)" : "no (using Homebrew install for development)")
                        LabeledContent("Connection URL") {
                            HStack(spacing: 8) {
                                if let url = try? appState.postgres.standardConnectionURL() {
                                    Text(PostgresService.redactedConnectionString(url))
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                    Button("Copy") {
                                        appState.copyDatabaseURLToClipboard()
                                    }
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

                GroupBox("Schema & Migrations") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center) {
                            if !appState.postgres.pendingMigrations.isEmpty {
                                Label {
                                    Text("\(appState.postgres.pendingMigrations.count) missing migration(s)")
                                        .font(.headline)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                }
                            } else if appState.postgres.status == .running {
                                Label {
                                    Text("Schema up to date")
                                        .font(.headline)
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            } else {
                                Label {
                                    Text("Migrations")
                                        .font(.headline)
                                } icon: {
                                    Image(systemName: "cylinder.split.1x2")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Check Migrations") {
                                appState.checkPendingMigrations()
                            }
                            .disabled(!isPostgresActive)

                            Button("Apply Migrations") {
                                Task {
                                    await appState.applyMigrations()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!isPostgresActive || appState.isApplyingMigrations)

                            if appState.isApplyingMigrations {
                                ProgressView().controlSize(.small)
                            }
                        }

                        if !appState.postgres.pendingMigrations.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("The following migrations have not been applied to the database:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(appState.postgres.pendingMigrations, id: \.self) { migration in
                                        HStack(spacing: 8) {
                                            Image(systemName: "doc.text.fill")
                                                .foregroundStyle(.secondary)
                                            Text(migration)
                                                .font(.system(.caption, design: .monospaced))
                                                .fontWeight(.medium)
                                            Spacer()
                                            StatusBadge("MISSING", tint: .orange)
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                    }
                                }
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                                )
                            }
                        }

                        Divider()

                        HStack {
                            Button("Initialize schema") {
                                Task {
                                    initRunning = true
                                    await appState.runOperation {
                                        try await $0.initDatabase(schemaDir: Paths.schemaDir.path).message
                                    }
                                    initRunning = false
                                }
                            }
                            .disabled(appState.postgres.status != .running || initRunning)

                            Button("Show stats") {
                                Task {
                                    statsRunning = true
                                    await appState.runOperation { try await $0.stats().summary }
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

                GroupBox("Database management") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Backups use PostgreSQL's portable custom dump format.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Back Up…") { chooseBackupDestination() }
                                .disabled(!isPostgresActive)
                                .accessibilityIdentifier("database.backup")
                            Button("Restore…") { chooseBackupSource() }
                                .disabled(!isPostgresActive)
                                .accessibilityIdentifier("database.restore")
                            Button("Reset Database…") { showResetConfirmation = true }
                                .tint(.red)
                                .accessibilityIdentifier("database.reset")
                                .disabled(
                                    appState.isResettingDatabase
                                        || appState.postgres.status == .starting
                                        || appState.postgres.status == .stopping
                                )
                            if appState.isResettingDatabase {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                LastCommandOutputBox(text: appState.lastCommandOutput, maxHeight: 260)
            }
            .padding(20)
        }
        .navigationTitle("Database")
        .onAppear {
            appState.checkPendingMigrations()
        }
        .sheet(isPresented: $showResetConfirmation) {
            DatabaseResetSheet()
                .environmentObject(appState)
        }
    }

    private func chooseBackupDestination() {
        guard let destination = DatabaseBackupPanel.chooseDestination() else { return }
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
}

/// The save panel for a database backup, shared by Back Up… and the reset sheet's Back Up First….
@MainActor
enum DatabaseBackupPanel {
    static func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Back Up Garage Database"
        panel.nameFieldStringValue = "garage-rag-\(timestamp()).dump"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
