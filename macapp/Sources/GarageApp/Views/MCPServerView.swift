import SwiftUI
import AppKit

/// One citation in a `rag_ask` result.
struct PlaygroundCitation: Decodable, Identifiable {
    let n: Int
    let documentId: Int?
    let title: String?
    let location: String?
    let snippet: String?
    let score: Double?

    var id: Int { n }

    enum CodingKeys: String, CodingKey {
        case n, title, location, snippet, score
        case documentId = "document_id"
    }
}

/// The JSON a `rag_ask` (`answer` + `citations`) or `rag_generate` (`text`) tool call returns.
struct PlaygroundAnswer: Decodable {
    let answer: String?
    let text: String?
    let model: String?
    let provider: String?
    let citations: [PlaygroundCitation]?

    var displayText: String { answer ?? text ?? "" }
    var hasText: Bool { answer != nil || text != nil }
}

@MainActor
struct MCPServerView: View {
    enum PlaygroundMode: String, CaseIterable, Identifiable {
        case rag = "Ask the corpus (RAG)"
        case raw = "Raw prompt"

        var id: String { rawValue }
        var defaultMaxTokens: Int { self == .rag ? 512 : 256 }
        var defaultTemperature: Double { self == .rag ? 0.2 : 0.7 }
    }

    @EnvironmentObject var appState: AppState
    @State private var busy = false
    @State private var selectedToolName = "rag_stats"
    @State private var testSearchQuery = "secure boot"
    @State private var testDocumentId = "1"
    @State private var toolExecutionOutput: String?
    @State private var isExecutingCustomTool = false
    @State private var customToolError: String?

    // Prompt Playground state
    @State private var playgroundPrompt = ""
    @State private var playgroundMode: PlaygroundMode = .rag
    @State private var playgroundMaxTokens: Int = PlaygroundMode.rag.defaultMaxTokens
    @State private var playgroundTemperature: Double = PlaygroundMode.rag.defaultTemperature
    @State private var isRunningPlayground = false
    @State private var playgroundError: String?
    @State private var playgroundAnswer: PlaygroundAnswer?
    @State private var playgroundRawOutput: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverStatusSection
                testingAndDiagnosticsSection
                promptPlaygroundSection
                clientIntegrationsSection
                serverDetailsSection
                LastCommandOutputBox(text: appState.lastCommandOutput)
            }
            .padding(20)
        }
        .navigationTitle("MCP Server")
        .onAppear {
            appState.mcp.refreshDetectedClients()
            appState.fetchFactsSettings()
        }
    }

    // MARK: - Prompt Playground Section

    private var isPlaygroundPromptEmpty: Bool {
        playgroundPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptPlaygroundSection: some View {
        GroupBox("Prompt Playground") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Send a prompt to the distillation model through the running MCP server: rag_ask retrieves from the corpus and answers with citations; rag_generate runs the raw prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Mode", selection: $playgroundMode) {
                    ForEach(PlaygroundMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: playgroundMode) { _, mode in
                    playgroundMaxTokens = mode.defaultMaxTokens
                    playgroundTemperature = mode.defaultTemperature
                }

                TextEditor(text: $playgroundPrompt)
                    .font(.system(.body, design: .default))
                    .frame(minHeight: 80, maxHeight: 160)
                    .border(Color.secondary.opacity(0.3), width: 1)

                HStack(spacing: 16) {
                    Stepper("Max tokens: \(playgroundMaxTokens)", value: $playgroundMaxTokens, in: 16...4096, step: 16)
                        .frame(width: 200)

                    HStack(spacing: 8) {
                        Text(String(format: "Temperature: %.2f", playgroundTemperature))
                        Slider(value: $playgroundTemperature, in: 0...1.5, step: 0.05)
                            .frame(width: 160)
                    }

                    Spacer()

                    Button {
                        runPlayground()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.mcp.status != .running || isRunningPlayground || isPlaygroundPromptEmpty)

                    if isRunningPlayground {
                        ProgressView().controlSize(.small)
                    }
                }

                if let err = playgroundError {
                    Text("Error: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let answer = playgroundAnswer {
                    playgroundAnswerView(answer)
                } else if let raw = playgroundRawOutput, !raw.isEmpty {
                    playgroundOutputBox(title: "Output", text: raw)
                }

                Text("Runs on the local facts model (\(appState.factsModel) via \(appState.factsProvider)); load it on the Models page.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }

    private func playgroundAnswerView(_ answer: PlaygroundAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(playgroundMode == .rag ? "Answer" : "Completion")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if let model = answer.model, !model.isEmpty {
                    StatusBadge(model, tint: .purple)
                }
                if let provider = answer.provider, !provider.isEmpty {
                    StatusBadge(provider, tint: .blue)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.copy(answer.displayText)
                }
                .controlSize(.small)
            }

            ScrollView {
                Text(answer.displayText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let citations = answer.citations, !citations.isEmpty {
                Text("Citations (\(citations.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(citations) { citation in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("[\(citation.n)]")
                                    .font(.system(.caption, design: .monospaced).bold())
                                Text(citation.title ?? "Untitled")
                                    .font(.caption.bold())
                                if let location = citation.location, !location.isEmpty {
                                    Text(location)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if let score = citation.score {
                                    Text(String(format: "%.3f", score))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let snippet = citation.snippet, !snippet.isEmpty {
                                Text(snippet)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private func playgroundOutputBox(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.copy(text)
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Sends the prompt as an MCP `tools/call` to the running garage-mcp server — the same
    /// path `executeSelectedTool` uses — so the playground exercises the distillation model
    /// exactly as an MCP client would.
    private func runPlayground() {
        let prompt = playgroundPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isRunningPlayground = true
        playgroundError = nil
        playgroundAnswer = nil
        playgroundRawOutput = nil
        Task {
            defer { isRunningPlayground = false }
            do {
                var args: [String: Any] = [
                    "max_tokens": playgroundMaxTokens,
                    "temperature": playgroundTemperature
                ]
                let toolName: String
                if playgroundMode == .rag {
                    toolName = "rag_ask"
                    args["question"] = prompt
                    args["limit"] = 6
                } else {
                    toolName = "rag_generate"
                    args["prompt"] = prompt
                }
                let output = try await appState.mcp.executeToolCall(toolName: toolName, arguments: args)
                if let data = output.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(PlaygroundAnswer.self, from: data),
                   parsed.hasText {
                    playgroundAnswer = parsed
                } else {
                    playgroundRawOutput = output
                }
            } catch {
                playgroundError = error.localizedDescription
            }
        }
    }

    // MARK: - Server Status Section

    private var serverStatusSection: some View {
        GroupBox("MCP Server Status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(appState.mcp.status.color)
                        .frame(width: 12, height: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.mcp.status.title)
                            .font(.headline)
                        Text(appState.mcp.status.detail(endpoint: appState.mcp.endpoint))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.mcp.status.isTransitioning || busy {
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
                            StatusBadge("PASS (200 OK)", tint: .green)
                            StatusBadge(String(format: "%.1f ms", res.latencyMs), tint: .blue)
                            StatusBadge("\(res.tools.count) TOOLS", tint: .purple)
                        } else {
                            StatusBadge("FAILED", tint: .red)
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
                        .disabled(appState.mcp.status != .running || isExecutingCustomTool || !isCustomToolInputValid)

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
                                    NSPasteboard.general.copy(output)
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
                                        StatusBadge("Config Found", tint: .green)
                                    } else {
                                        StatusBadge("No config file", tint: .secondary)
                                    }

                                    if client.isRegistered {
                                        StatusBadge("Registered", tint: .blue)
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
                            format: .number.grouping(.never)
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

    // MARK: - Helpers & Actions


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

    private var parsedTestDocumentId: Int? {
        Int(testDocumentId.trimmingCharacters(in: .whitespaces))
    }

    private var isCustomToolInputValid: Bool {
        selectedToolName != "rag_get_document" || parsedTestDocumentId != nil
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
                    guard let docId = parsedTestDocumentId else {
                        customToolError = "Document ID must be an integer."
                        return
                    }
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
