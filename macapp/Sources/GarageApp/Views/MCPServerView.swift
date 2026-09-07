import SwiftUI
import AppKit

@MainActor
struct MCPServerView: View {
    @EnvironmentObject var appState: AppState
    @State private var busy = false
    @State private var selectedToolName = "rag_stats"
    @State private var testSearchQuery = "secure boot"
    @State private var testDocumentId = "1"
    @State private var toolExecutionOutput: String?
    @State private var isExecutingCustomTool = false
    @State private var customToolError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverStatusSection
                testingAndDiagnosticsSection
                clientIntegrationsSection
                serverDetailsSection
                if !appState.lastCommandOutput.isEmpty {
                    lastCommandOutputSection
                }
            }
            .padding(20)
        }
        .navigationTitle("MCP Server")
        .onAppear {
            appState.mcp.refreshDetectedClients()
        }
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

    // MARK: - Testing & Diagnostics Section

    private var testingAndDiagnosticsSection: some View {
        GroupBox("Testing & Diagnostics") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Test the running MCP server over loopback HTTP JSON-RPC, verify tool availability, and inspect tool call responses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(action: runServerDiagnostics) {
                        Label("Test MCP Server", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.mcp.status != .running || appState.mcp.isTesting || busy)

                    if appState.mcp.isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing endpoint & querying tools…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let res = appState.mcp.lastTestResult {
                        if res.isSuccess {
                            badgeView(
                                text: "PASS (200 OK)",
                                bg: Color.green.opacity(0.15),
                                fg: .green
                            )
                            badgeView(
                                text: String(format: "%.1f ms", res.latencyMs),
                                bg: Color.blue.opacity(0.15),
                                fg: .blue
                            )
                            badgeView(
                                text: "\(res.tools.count) TOOLS",
                                bg: Color.purple.opacity(0.15),
                                fg: .purple
                            )
                        } else {
                            badgeView(
                                text: "FAILED",
                                bg: Color.red.opacity(0.15),
                                fg: .red
                            )
                        }
                    }

                    Spacer()
                }

                if let res = appState.mcp.lastTestResult, !res.isSuccess, let err = res.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text("Diagnostics failed: \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                // Interactive Tool Execution
                VStack(alignment: .leading, spacing: 10) {
                    Text("Interactive Tool Testing")
                        .font(.subheadline.bold())

                    HStack(spacing: 10) {
                        Picker("Tool", selection: $selectedToolName) {
                            Text("rag_stats (Corpus Statistics)").tag("rag_stats")
                            Text("rag_search (Hybrid RAG Search)").tag("rag_search")
                            Text("rag_list_sources (List Sources)").tag("rag_list_sources")
                            Text("rag_list_authors (List Authors)").tag("rag_list_authors")
                            Text("rag_get_document (Document Details)").tag("rag_get_document")
                        }
                        .frame(width: 260)
                        .disabled(appState.mcp.status != .running)

                        if selectedToolName == "rag_search" {
                            TextField("Search Query", text: $testSearchQuery)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 240)
                        } else if selectedToolName == "rag_get_document" {
                            TextField("Document ID", text: $testDocumentId)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }

                        Button("Execute Tool") {
                            executeSelectedTool()
                        }
                        .disabled(appState.mcp.status != .running || isExecutingCustomTool)

                        if isExecutingCustomTool {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if let err = customToolError {
                        Text("Execution error: \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    let outputToShow = toolExecutionOutput ?? appState.mcp.lastTestResult?.toolOutput
                    if let output = outputToShow, !output.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Response Output")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(output, forType: .string)
                                }
                                .controlSize(.small)
                            }

                            ScrollView {
                                Text(output)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 180)
                            .padding(8)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // Discovered Tools Catalog
                if let res = appState.mcp.lastTestResult, !res.tools.isEmpty {
                    DisclosureGroup("Registered Server Tools (\(res.tools.count))") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(res.tools) { tool in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(tool.name)
                                            .font(.system(.caption, design: .monospaced).bold())
                                        Spacer()
                                    }
                                    Text(tool.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: - Client Integrations Section

    private var clientIntegrationsSection: some View {
        GroupBox("Client Integrations & Configuration") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Register Garage's MCP tools with any detected local AI assistants and editors. You can batch-register all found configuration files or target specific clients.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(action: registerAllFound) {
                        Label("Register All Found Configs", systemImage: "square.stack.3d.up.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || appState.mcp.isRegistering)

                    Button("Add Custom Config File…") {
                        chooseCustomConfigFile()
                    }
                    .disabled(busy || appState.mcp.isRegistering)

                    Button("Refresh List") {
                        appState.mcp.refreshDetectedClients()
                    }
                    .disabled(busy || appState.mcp.isRegistering)

                    Button("Check MCP Status") {
                        runMCPCommand(["mcp-status"])
                    }
                    .disabled(busy || appState.mcp.isRegistering)

                    if appState.mcp.isRegistering {
                        ProgressView().controlSize(.small)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Detected Client Configurations:")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ForEach(appState.mcp.detectedClients) { client in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(client.label)
                                        .font(.subheadline.bold())

                                    if client.existsOnDisk {
                                        badgeView(text: "Config Found", bg: Color.green.opacity(0.12), fg: .green)
                                    } else {
                                        badgeView(text: "No config file", bg: Color.secondary.opacity(0.12), fg: .secondary)
                                    }

                                    if client.isRegistered {
                                        badgeView(text: "Registered", bg: Color.blue.opacity(0.15), fg: .blue)
                                    }
                                }

                                Text(client.path.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if !client.note.isEmpty {
                                    Text(client.note)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button(client.isRegistered ? "Re-register" : "Register") {
                                registerClient(client.id)
                            }
                            .controlSize(.small)
                            .disabled(busy || appState.mcp.isRegistering)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
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
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField(
                            "Port",
                            value: Binding(
                                get: { appState.mcp.port },
                                set: { newPort in
                                    if (1...65535).contains(newPort) {
                                        appState.mcp.port = newPort
                                    }
                                }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .disabled(appState.mcp.status == .running || appState.mcp.status == .starting || busy)

                        Button("Random") {
                            appState.mcp.selectRandomPort()
                        }
                        .disabled(appState.mcp.status == .running || appState.mcp.status == .starting || busy)
                    }
                }
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

    private func badgeView(text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
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

    private func runServerDiagnostics() {
        Task {
            let res = await appState.mcp.testServerConnection(
                sampleTool: selectedToolName,
                query: testSearchQuery
            )
            if res.isSuccess {
                appState.lastCommandSucceeded = true
                appState.lastCommandOutput = "MCP Server test passed (\(String(format: "%.1f", res.latencyMs))ms). \(res.tools.count) tools discovered."
            } else {
                appState.lastCommandSucceeded = false
                appState.lastCommandOutput = res.errorMessage ?? "MCP Server test failed."
            }
        }
    }

    private func executeSelectedTool() {
        isExecutingCustomTool = true
        customToolError = nil
        Task {
            defer { isExecutingCustomTool = false }
            do {
                var args: [String: Any] = [:]
                if selectedToolName == "rag_search" {
                    args["query"] = testSearchQuery
                } else if selectedToolName == "rag_get_document" {
                    let docId = Int(testDocumentId.trimmingCharacters(in: .whitespaces)) ?? 1
                    args["document_id"] = docId
                }
                let output = try await appState.mcp.executeToolCall(toolName: selectedToolName, arguments: args)
                toolExecutionOutput = output
            } catch {
                customToolError = error.localizedDescription
            }
        }
    }

    private func registerAllFound() {
        busy = true
        Task {
            let (success, message) = await appState.mcp.registerInAllFoundConfigs(force: true)
            appState.lastCommandSucceeded = success
            appState.lastCommandOutput = message
            busy = false
        }
    }

    private func registerClient(_ clientId: String) {
        busy = true
        Task {
            let (success, message) = await appState.mcp.registerTarget(clientId, force: true)
            appState.lastCommandSucceeded = success
            appState.lastCommandOutput = message
            busy = false
        }
    }

    private func chooseCustomConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "Select MCP Client Configuration File"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            let (success, message) = await appState.mcp.registerCustomConfigFile(at: url, force: true)
            appState.lastCommandSucceeded = success
            appState.lastCommandOutput = message
            busy = false
        }
    }

    private func runMCPCommand(_ arguments: [String]) {
        busy = true
        Task {
            await appState.runGarage(arguments)
            appState.mcp.refreshDetectedClients()
            busy = false
        }
    }
}
