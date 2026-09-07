import SwiftUI
import AppKit

@MainActor
struct StatusView: View {
    @EnvironmentObject var appState: AppState

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
                    }
                    .padding(8)
                }

                GroupBox("Sandbox & Volume Access") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Status", value: appState.volumeAccess.status.displayDescription)
                        if let rootURL = appState.volumeAccess.activeRootURL {
                            LabeledContent("Root path", value: rootURL.path)
                        }
                        HStack {
                            Button("Select Root Drive…") {
                                appState.promptAndSelectRootVolume()
                            }
                            Button("Test Volume Access") {
                                appState.testVolumeAccess()
                            }
                            if appState.volumeAccess.status.isGranted {
                                Button("Revoke") {
                                    appState.revokeVolumeAccess()
                                }
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("garage CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Binary", value: Paths.garageCLI.path)
                        LabeledContent("Available", value: appState.garage.cliAvailable ? "yes" : "not found")
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
