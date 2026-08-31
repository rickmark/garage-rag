import SwiftUI
import AppKit

struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @State private var initRunning = false
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

                GroupBox("garage CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Binary", value: Paths.garageCLI.path)
                        LabeledContent("Available", value: appState.garage.cliAvailable ? "yes" : "not found")

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
                                Task { await appState.runGarage(["stats"]) }
                            }
                            .disabled(appState.postgres.status != .running)

                            if initRunning {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("MCP server") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Endpoint", value: appState.mcp.endpoint.absoluteString)
                        LabeledContent("Status", value: mcpStatusSummary)
                        Text("The app runs `garage-mcp` as a loopback-only HTTP service. Client registrations below continue to use their own stdio process.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Start") {
                                Task { await appState.startPostgres() }
                            }
                            .disabled(
                                appState.postgres.status != .running ||
                                    appState.mcp.status == .running ||
                                    appState.mcp.status == .starting
                            )
                            Button("Stop") {
                                Task { await appState.mcp.stop() }
                            }
                            .disabled(
                                appState.mcp.status != .running &&
                                    appState.mcp.status != .starting
                            )

                            Button("Register with Claude Desktop") {
                                Task { await appState.runGarage(["mcp-install", "--target", "claude-desktop", "--yes"]) }
                            }
                            Button("Register with Claude Code (project)") {
                                Task { await appState.runGarage(["mcp-install", "--target", "project", "--yes"]) }
                            }
                            Button("Status") {
                                Task { await appState.runGarage(["mcp-status"]) }
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
        .navigationTitle("Status")
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

    private var mcpStatusSummary: String {
        switch appState.mcp.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
