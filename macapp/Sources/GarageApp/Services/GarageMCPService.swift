import Foundation

enum GarageMCPStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

enum GarageMCPError: LocalizedError, Equatable {
    case databaseNotOnline
    case cliNotFound
    case startupTimeout
    case launchFailed(String)
    case serverNotRunning
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotOnline:
            "Database is not online. MCP server requires an online database."
        case .cliNotFound:
            "garage CLI not found at \(Paths.garageCLI.path)"
        case .startupTimeout:
            "garage-mcp did not become ready within 10 seconds"
        case .launchFailed(let message):
            "failed to launch garage-mcp: \(message)"
        case .serverNotRunning:
            "MCP server is not running."
        case .invalidResponse(let message):
            "Invalid MCP server response: \(message)"
        }
    }
}

public struct MCPClientConfig: Identifiable, Equatable {
    public var id: String
    public var label: String
    public var path: URL
    public var existsOnDisk: Bool
    public var isRegistered: Bool
    public var isProjectScoped: Bool
    public var note: String

    public init(
        id: String,
        label: String,
        path: URL,
        existsOnDisk: Bool,
        isRegistered: Bool,
        isProjectScoped: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.existsOnDisk = existsOnDisk
        self.isRegistered = isRegistered
        self.isProjectScoped = isProjectScoped
        self.note = note
    }
}

public struct MCPToolInfo: Identifiable, Equatable, Hashable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var inputSchemaJson: String?

    public init(name: String, description: String, inputSchemaJson: String? = nil) {
        self.name = name
        self.description = description
        self.inputSchemaJson = inputSchemaJson
    }
}

public struct MCPTestResult: Equatable {
    public var isSuccess: Bool
    public var timestamp: Date
    public var latencyMs: Double
    public var httpStatusCode: Int?
    public var tools: [MCPToolInfo]
    public var testedToolName: String?
    public var toolOutput: String?
    public var errorMessage: String?

    public init(
        isSuccess: Bool,
        timestamp: Date = Date(),
        latencyMs: Double = 0,
        httpStatusCode: Int? = nil,
        tools: [MCPToolInfo] = [],
        testedToolName: String? = nil,
        toolOutput: String? = nil,
        errorMessage: String? = nil
    ) {
        self.isSuccess = isSuccess
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.httpStatusCode = httpStatusCode
        self.tools = tools
        self.testedToolName = testedToolName
        self.toolOutput = toolOutput
        self.errorMessage = errorMessage
    }
}

/// Owns the app-managed, loopback-only HTTP `garage-mcp` server.
@MainActor
final class GarageMCPService: ObservableObject {
    nonisolated static let defaultPort = 8787
    nonisolated static let portDefaultsKey = "garage.mcp.port"

    @Published private(set) var status: GarageMCPStatus = .stopped
    @Published private(set) var logs: [LogLine] = []
    @Published var port: Int {
        didSet {
            defaults.set(port, forKey: Self.portDefaultsKey)
        }
    }
    @Published private(set) var detectedClients: [MCPClientConfig] = []
    @Published private(set) var lastTestResult: MCPTestResult?
    @Published private(set) var isTesting: Bool = false
    @Published private(set) var isRegistering: Bool = false
    @Published private(set) var sessionId: String?

    let host = "127.0.0.1"
    let path = "/mcp"

    private let postgres: PostgresService
    private let runner: ProcessRunner
    private let defaults: UserDefaults
    private let maxLogLines = 4000
    private var isStopping = false

    init(
        postgres: PostgresService,
        port: Int? = nil,
        runner: ProcessRunner = ProcessRunner(),
        defaults: UserDefaults = .standard
    ) {
        self.postgres = postgres
        self.runner = runner
        self.defaults = defaults
        if let port {
            self.port = port
        } else {
            let savedPort = defaults.integer(forKey: Self.portDefaultsKey)
            self.port = (1...65535).contains(savedPort) ? savedPort : Self.defaultPort
        }
        refreshDetectedClients()
    }

    var endpoint: URL {
        URL(string: "http://\(host):\(port)\(path)")!
    }

    nonisolated static func randomPort(excluding: Set<Int> = []) -> Int {
        var candidate: Int
        repeat {
            candidate = Int.random(in: 1024...65535)
        } while excluding.contains(candidate)
        return candidate
    }

    @discardableResult
    func selectRandomPort() -> Int {
        let newPort = Self.randomPort(excluding: [port])
        self.port = newPort
        return newPort
    }

    // MARK: - Client Configuration Detection

    func refreshDetectedClients() {
        self.detectedClients = detectClientConfigs()
    }

    func detectClientConfigs() -> [MCPClientConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let project = Paths.garageWorkingDirectory
        let appSupport = home.appendingPathComponent("Library/Application Support")

        let standardTargets: [(id: String, label: String, path: URL, projectScoped: Bool, note: String)] = [
            (
                id: "project",
                label: "Claude Code (project config)",
                path: project.appendingPathComponent(".mcp.json"),
                projectScoped: true,
                note: "Shared with collaborators in the repository"
            ),
            (
                id: "claude-desktop",
                label: "Claude Desktop",
                path: appSupport.appendingPathComponent("Claude/claude_desktop_config.json"),
                projectScoped: false,
                note: "Official Claude Desktop macOS app"
            ),
            (
                id: "claude-code-user",
                label: "Claude Code (user config)",
                path: home.appendingPathComponent(".claude.json"),
                projectScoped: false,
                note: "Global Claude Code user configuration"
            ),
            (
                id: "lmstudio",
                label: "LM Studio",
                path: home.appendingPathComponent(".lmstudio/mcp.json"),
                projectScoped: false,
                note: "LM Studio local AI assistant"
            ),
            (
                id: "cursor",
                label: "Cursor",
                path: home.appendingPathComponent(".cursor/mcp.json"),
                projectScoped: false,
                note: "Cursor AI editor configuration"
            ),
            (
                id: "cursor-global",
                label: "Cursor (extension global)",
                path: appSupport.appendingPathComponent("Cursor/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                projectScoped: false,
                note: "Cursor Cline/Roo-Code extension settings"
            ),
            (
                id: "vscode",
                label: "VS Code (project)",
                path: project.appendingPathComponent(".vscode/mcp.json"),
                projectScoped: true,
                note: "Workspace-specific VS Code MCP config"
            ),
            (
                id: "vscode-global",
                label: "VS Code (extension global)",
                path: appSupport.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                projectScoped: false,
                note: "VS Code Cline/Roo-Code extension settings"
            ),
            (
                id: "windsurf",
                label: "Windsurf",
                path: home.appendingPathComponent(".codeium/windsurf/mcp_config.json"),
                projectScoped: false,
                note: "Codeium Windsurf AI IDE"
            ),
            (
                id: "zed",
                label: "Zed",
                path: home.appendingPathComponent(".config/zed/settings.json"),
                projectScoped: false,
                note: "Zed editor settings"
            ),
        ]

        return standardTargets.map { target in
            let exists = FileManager.default.fileExists(atPath: target.path.path)
            let isRegistered = checkIsRegistered(at: target.path)
            return MCPClientConfig(
                id: target.id,
                label: target.label,
                path: target.path,
                existsOnDisk: exists,
                isRegistered: isRegistered,
                isProjectScoped: target.projectScoped,
                note: target.note
            )
        }
    }

    private func checkIsRegistered(at url: URL, serverName: String = "garage-rag") -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers[serverName] != nil
    }

    // MARK: - Client Registration Actions

    private func runCliCommand(_ arguments: [String]) async -> (success: Bool, message: String) {
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            return (false, GarageMCPError.cliNotFound.localizedDescription)
        }

        var collected: [String] = []
        let tempRunner = ProcessRunner()
        let process: Process
        do {
            process = try tempRunner.run(
                executable: Paths.garageCLI,
                arguments: arguments,
                environment: (try? environment()) ?? [:],
                currentDirectory: Paths.garageWorkingDirectory,
                source: "garage-mcp"
            ) { [weak self] line in
                self?.appendLog(line)
                collected.append(line.text)
            }
        } catch {
            return (false, "Failed to launch CLI: \(error.localizedDescription)")
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                DispatchQueue.main.async {
                    let output = collected.joined(separator: "\n")
                    let success = proc.terminationStatus == 0
                    continuation.resume(returning: (success, output.isEmpty ? (success ? "Command succeeded." : "Command failed.") : output))
                }
            }
        }
    }

    @discardableResult
    func registerInAllFoundConfigs(force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }

        var args = ["mcp-install", "--all", "--yes", "--port", "\(port)", "--host", host]
        if force {
            args.append("--force")
        }
        return await runCliCommand(args)
    }

    @discardableResult
    func registerTarget(_ targetId: String, force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }

        var args = ["mcp-install", "--target", targetId, "--yes", "--port", "\(port)", "--host", host]
        if force {
            args.append("--force")
        }
        return await runCliCommand(args)
    }

    @discardableResult
    func registerCustomConfigFile(at url: URL, force: Bool = true) async -> (success: Bool, message: String) {
        isRegistering = true
        defer {
            isRegistering = false
            refreshDetectedClients()
        }

        var args = ["mcp-install", "--path", url.path, "--yes", "--port", "\(port)", "--host", host]
        if force {
            args.append("--force")
        }
        return await runCliCommand(args)
    }

    // MARK: - Testing & Diagnostics

    func initializeSession() async throws {
        self.sessionId = nil
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "GarageAppDiagnostic",
                    "version": "1.0.0"
                ]
            ]
        ]
        _ = try await sendJSONRPC(initPayload)

        let initNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [String: Any]()
        ]
        _ = try? await sendJSONRPC(initNotification)
    }

    @discardableResult
    func testServerConnection(sampleTool: String? = "rag_stats", query: String? = nil) async -> MCPTestResult {
        isTesting = true
        defer { isTesting = false }

        let startTime = CFAbsoluteTimeGetCurrent()
        guard status == .running else {
            let res = MCPTestResult(
                isSuccess: false,
                latencyMs: 0,
                tools: [],
                errorMessage: "MCP server is not running (status: \(status))"
            )
            self.lastTestResult = res
            return res
        }

        do {
            // 1. Initialize session
            try await initializeSession()

            // 2. Query tools/list
            let listToolsPayload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": [String: Any]()
            ]
            let listResp = try await sendJSONRPC(listToolsPayload)

            var parsedTools: [MCPToolInfo] = []
            if let result = listResp["result"] as? [String: Any],
               let toolsArray = result["tools"] as? [[String: Any]] {
                for t in toolsArray {
                    let name = t["name"] as? String ?? "unknown"
                    let desc = t["description"] as? String ?? ""
                    let schema = t["inputSchema"] as? [String: Any]
                    let schemaStr = schema != nil ? (try? String(data: JSONSerialization.data(withJSONObject: schema!, options: .prettyPrinted), encoding: .utf8)) : nil
                    parsedTools.append(MCPToolInfo(name: name, description: desc, inputSchemaJson: schemaStr))
                }
            }

            // 3. Test sample tool invocation if requested
            var toolOutputText: String?
            let toolToTest = sampleTool ?? (parsedTools.first?.name ?? "rag_stats")
            if !toolToTest.isEmpty {
                var toolArgs: [String: Any] = [:]
                if toolToTest == "rag_search" {
                    toolArgs["query"] = query ?? "test search"
                }
                toolOutputText = try? await executeToolCall(toolName: toolToTest, arguments: toolArgs)
            }

            let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let testResult = MCPTestResult(
                isSuccess: true,
                latencyMs: latency,
                httpStatusCode: 200,
                tools: parsedTools,
                testedToolName: toolToTest,
                toolOutput: toolOutputText,
                errorMessage: nil
            )
            self.lastTestResult = testResult
            return testResult
        } catch {
            let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            let testResult = MCPTestResult(
                isSuccess: false,
                latencyMs: latency,
                tools: [],
                errorMessage: error.localizedDescription
            )
            self.lastTestResult = testResult
            return testResult
        }
    }

    func executeToolCall(toolName: String, arguments: [String: Any] = [:]) async throws -> String {
        if sessionId == nil {
            try await initializeSession()
        }

        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 100...9999),
            "method": "tools/call",
            "params": [
                "name": toolName,
                "arguments": arguments
            ]
        ]

        let resp: [String: Any]
        do {
            resp = try await sendJSONRPC(callPayload)
        } catch {
            if let mcpError = error as? GarageMCPError,
               case .invalidResponse(let msg) = mcpError,
               msg.localizedCaseInsensitiveContains("session") {
                try await initializeSession()
                resp = try await sendJSONRPC(callPayload)
            } else {
                throw error
            }
        }

        if let errorObj = resp["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Unknown error"
            throw GarageMCPError.invalidResponse("Tool call failed: \(message)")
        }

        if let result = resp["result"] as? [String: Any] {
            if let content = result["content"] as? [[String: Any]] {
                let texts = content.compactMap { $0["text"] as? String }
                if !texts.isEmpty {
                    return texts.joined(separator: "\n")
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }

        return "Tool executed successfully (empty response)."
    }

    private func sendJSONRPC(_ payload: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = self.sessionId, !sid.isEmpty {
            request.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw GarageMCPError.invalidResponse("No HTTP response received")
        }

        if let newSessionId = httpResp.value(forHTTPHeaderField: "mcp-session-id") ?? httpResp.value(forHTTPHeaderField: "Mcp-Session-Id"),
           !newSessionId.isEmpty {
            self.sessionId = newSessionId
        }

        guard (200...299).contains(httpResp.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            if (httpResp.statusCode == 400 || httpResp.statusCode == 404) && bodyStr.localizedCaseInsensitiveContains("session") {
                self.sessionId = nil
            }
            throw GarageMCPError.invalidResponse("HTTP \(httpResp.statusCode): \(bodyStr)")
        }

        if data.isEmpty {
            return [:]
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        if let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("data:") {
                    let jsonPart = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let jsonData = jsonPart.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        return json
                    }
                }
            }
        }

        return [:]
    }

    // MARK: - Server Lifecycle

    func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws {
        guard status == .stopped || isFailed else { return }
        guard postgres.status == .running else {
            let errorMsg = "Database is not online (status: \(postgres.status)). MCP server requires an online database."
            status = .failed(errorMsg)
            appendLog(LogLine(stream: .stderr, text: errorMsg, source: "garage-mcp"))
            throw GarageMCPError.databaseNotOnline
        }
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            status = .failed(GarageMCPError.cliNotFound.localizedDescription)
            throw GarageMCPError.cliNotFound
        }

        var attemptsLeft = max(1, maxAttempts)
        var triedPorts: Set<Int> = []

        while attemptsLeft > 0 {
            let currentPort = port
            triedPorts.insert(currentPort)
            status = .starting
            isStopping = false
            sessionId = nil

            var processInstance: Process?
            do {
                let process = try runner.run(
                    executable: Paths.garageCLI,
                    arguments: [
                        "mcp-serve",
                        "--http",
                        "--host", host,
                        "--port", String(currentPort),
                        "--path", path,
                    ],
                    environment: try environment(),
                    currentDirectory: Paths.garageWorkingDirectory,
                    source: "garage-mcp"
                ) { [weak self] line in
                    self?.appendLog(line)
                }
                processInstance = process
                process.terminationHandler = { [weak self] process in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.status = self.isStopping
                            ? .stopped
                            : .failed("garage-mcp exited with status \(process.terminationStatus)")
                    }
                }
            } catch {
                let launchError = GarageMCPError.launchFailed(error.localizedDescription)
                status = .failed(launchError.localizedDescription)
                throw launchError
            }

            let ready = await waitUntilReady(timeout: readyTimeout)
            if ready {
                status = .running
                refreshDetectedClients()
                return
            }

            // Startup / loading failed on currentPort
            attemptsLeft -= 1
            processInstance?.terminationHandler = nil
            runner.terminate()
            for _ in 0..<20 where runner.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            if attemptsLeft > 0 {
                let newPort = Self.randomPort(excluding: triedPorts)
                appendLog(LogLine(
                    stream: .stderr,
                    text: "Failed to load garage-mcp on port \(currentPort); selecting random port \(newPort)…",
                    source: "garage-mcp"
                ))
                self.port = newPort
            } else {
                status = .failed(GarageMCPError.startupTimeout.localizedDescription)
                throw GarageMCPError.startupTimeout
            }
        }
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        isStopping = true
        sessionId = nil
        runner.terminate()
        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        status = .stopped
    }

    func terminateImmediately() {
        isStopping = true
        sessionId = nil
        runner.terminate()
    }

    private var isFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    private func appendLog(_ line: LogLine) {
        logs.append(line)
        if logs.count > maxLogLines {
            logs.removeFirst(logs.count - maxLogLines)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func environment() throws -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GARAGE_DATABASE_URL"] = try postgres.connectionURL()
        let libpqURL = Paths.postgresLibDir.appendingPathComponent("libpq.dylib")
        if FileManager.default.fileExists(atPath: libpqURL.path) {
            env["GARAGE_LIBPQ_PATH"] = libpqURL.path
        }
        if let lmStudioToken = try LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }
        return env
    }

    private func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard runner.isRunning else { return false }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 1
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if response is HTTPURLResponse {
                    return true
                }
            } catch {
                // The server may still be starting; retry until the timeout.
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
