import SwiftUI
import AppKit

@MainActor
struct MCPServerView: View {
    @EnvironmentObject var appState: AppState
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverStatusSection
                clientIntegrationsSection
                serverDetailsSection
                if !appState.lastCommandOutput.isEmpty {
                    lastCommandOutputSection
                }
            }
            .padding(20)
        }
        .navigationTitle("MCP Server")
    }

    // MARK: - Server Status Section

    private var serverStatusSection: some View {
        GroupBox("MCP Server Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(mcpStatusColor)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(mcpStatusTitle)
                            .font(.headline)
                        Text(mcpStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isTransitioning || busy {
                        ProgressView().controlSize(.small)
                    }

                    Button("Start") {
                        startServer()
                    }
                    .disabled(
                        appState.mcp.status == .running ||
                        appState.mcp.status == .starting ||
                        busy
                    )

                    Button("Stop") {
                        stopServer()
                    }
                    .disabled(
                        (appState.mcp.status != .running && appState.mcp.status != .starting) ||
                        busy
                    )

                    Button("Restart") {
                        restartServer()
                    }
                    .disabled(
                        appState.mcp.status != .running ||
                        busy
                    )
                }

                if appState.postgres.status != .running {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("PostgreSQL is stopped. Starting the MCP server will also start PostgreSQL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Client Integrations Section

    private var clientIntegrationsSection: some View {
        GroupBox("Client Integrations") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Register Garage's MCP tools with local AI assistants. Client registrations configure MCP clients (such as Claude Desktop or Claude Code) to communicate with Garage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Register with Claude Desktop") {
                        runMCPCommand(["mcp-install", "--target", "claude-desktop", "--yes"])
                    }
                    .disabled(busy)

                    Button("Register with Claude Code (project)") {
                        runMCPCommand(["mcp-install", "--target", "project", "--yes"])
                    }
                    .disabled(busy)

                    Button("Check MCP Status") {
                        runMCPCommand(["mcp-status"])
                    }
                    .disabled(busy)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Server Details Section

    private var serverDetailsSection: some View {
        GroupBox("Server Configuration & Endpoints") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Endpoint URL", value: appState.mcp.endpoint.absoluteString)
                LabeledContent("Host", value: appState.mcp.host)
                LabeledContent("Port", value: String(appState.mcp.port))
                LabeledContent("Path", value: appState.mcp.path)
                LabeledContent("Transport", value: "HTTP (Loopback) & Stdio (CLI)")
                LabeledContent("Database Dependency", value: appState.postgres.status == .running ? "PostgreSQL Connected (Port \(appState.postgres.port))" : "PostgreSQL Disconnected")

                Text("The app runs `garage-mcp` as a loopback-only HTTP service on \(appState.mcp.host):\(appState.mcp.port). Client registrations continue to use their own stdio process when invoked by external tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(10)
        }
    }

    // MARK: - Last Command Output Section

    private var lastCommandOutputSection: some View {
        GroupBox("Last Command Output") {
            ScrollView {
                Text(appState.lastCommandOutput)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(8)
        }
    }

    // MARK: - Helpers & Actions

    private var isTransitioning: Bool {
        appState.mcp.status == .starting || appState.mcp.status == .stopping
    }

    private var mcpStatusTitle: String {
        switch appState.mcp.status {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .failed: "Failed"
        }
    }

    private var mcpStatusDescription: String {
        switch appState.mcp.status {
        case .stopped:
            return "MCP server is not running."
        case .starting:
            return "Starting garage-mcp on \(appState.mcp.endpoint.absoluteString)…"
        case .running:
            return "Listening for requests on \(appState.mcp.endpoint.absoluteString)."
        case .stopping:
            return "Stopping garage-mcp process…"
        case .failed(let message):
            return message
        }
    }

    private var mcpStatusColor: Color {
        switch appState.mcp.status {
        case .running: return .green
        case .starting, .stopping: return .blue
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private func startServer() {
        busy = true
        Task {
            if appState.postgres.status != .running {
                await appState.startPostgres()
            } else {
                try? await appState.mcp.start()
            }
            busy = false
        }
    }

    private func stopServer() {
        busy = true
        Task {
            await appState.mcp.stop()
            busy = false
        }
    }

    private func restartServer() {
        busy = true
        Task {
            await appState.mcp.stop()
            if appState.postgres.status != .running {
                await appState.startPostgres()
            } else {
                try? await appState.mcp.start()
            }
            busy = false
        }
    }

    private func runMCPCommand(_ arguments: [String]) {
        busy = true
        Task {
            await appState.runGarage(arguments)
            busy = false
        }
    }
}
