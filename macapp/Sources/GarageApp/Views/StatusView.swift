import SwiftUI

struct StatusView: View {
    @EnvironmentObject var appState: AppState
    @State private var initRunning = false

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

                GroupBox("garage CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Binary", value: Paths.garageCLI.path)
                        LabeledContent("Available", value: appState.garage.cliAvailable ? "yes" : "not found")

                        HStack {
                            Button("Initialize schema (garage init-db)") {
                                Task {
                                    initRunning = true
                                    await appState.runGarage(["init-db"])
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
                        Text("An MCP client (Claude Desktop, Claude Code, ...) spawns `garage-mcp` itself over stdio once registered. This app just needs Postgres running on port \(appState.postgres.port) for that process to connect to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
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
    }
}
