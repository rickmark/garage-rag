import Foundation
import GRPC
import NIO
import SwiftProtobuf
import proto_garage_proto_swift

public enum GarageGRPCStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

public enum GarageGRPCError: LocalizedError {
    case databaseNotOnline
    case cliNotFound
    case startupTimeout
    case launchFailed(String)
    case serverNotRunning
    case searchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotOnline:
            return "Database is not online. gRPC server requires an online database."
        case .cliNotFound:
            return "garage CLI not found at \(Paths.garageCLI.path)"
        case .startupTimeout:
            return "Timed out waiting for gRPC server to start."
        case .launchFailed(let message):
            return "Failed to launch garage server: \(message)"
        case .serverNotRunning:
            return "gRPC server is not running."
        case .searchFailed(let message):
            return "Search request failed: \(message)"
        }
    }
}

@MainActor
final class GarageGRPCService: ObservableObject {
    @Published private(set) var logs: [LogLine] = []
    @Published private(set) var status: GarageGRPCStatus = .stopped
    @Published var host: String = "127.0.0.1"
    @Published var port: Int = 50051

    private let postgres: PostgresService
    private let runner = ProcessRunner()
    private var group: EventLoopGroup?
    private var channel: GRPCChannel?
    private var isStopping = false
    private let maxLogLines = 4000

    init(postgres: PostgresService, port: Int = 50051) {
        self.postgres = postgres
        self.port = port
    }

    deinit {
        try? group?.syncShutdownGracefully()
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
        if let lmStudioToken = try LMStudioTokenStore.load() {
            env["GARAGE_LMSTUDIO_API_TOKEN"] = lmStudioToken
        }
        return env
    }

    func start(maxAttempts: Int = 3, readyTimeout: TimeInterval = 10) async throws {
        guard status == .stopped || isFailed else { return }
        guard postgres.status == .running else {
            let errorMsg = "Database is not online. gRPC server requires an online database."
            status = .failed(errorMsg)
            appendLog(LogLine(stream: .stderr, text: errorMsg, source: "garage-grpc"))
            throw GarageGRPCError.databaseNotOnline
        }
        guard FileManager.default.isExecutableFile(atPath: Paths.garageCLI.path) else {
            let errorMsg = GarageGRPCError.cliNotFound.localizedDescription
            status = .failed(errorMsg)
            throw GarageGRPCError.cliNotFound
        }

        var attemptsLeft = max(1, maxAttempts)
        var triedPorts: Set<Int> = []

        while attemptsLeft > 0 {
            let currentPort = port
            triedPorts.insert(currentPort)
            status = .starting
            isStopping = false

            var processInstance: Process?
            do {
                let process = try runner.run(
                    executable: Paths.garageCLI,
                    arguments: [
                        "serve",
                        "--host", host,
                        "--port", String(currentPort),
                    ],
                    environment: try environment(),
                    currentDirectory: Paths.garageWorkingDirectory,
                    source: "garage-grpc"
                ) { [weak self] line in
                    self?.appendLog(line)
                }
                processInstance = process
                process.terminationHandler = { [weak self] process in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.status = self.isStopping
                            ? .stopped
                            : .failed("garage serve exited with status \(process.terminationStatus)")
                        self.cleanupChannel()
                    }
                }
            } catch {
                let launchError = GarageGRPCError.launchFailed(error.localizedDescription)
                status = .failed(launchError.localizedDescription)
                throw launchError
            }

            let ready = await waitUntilReady(timeout: readyTimeout)
            if ready {
                status = .running
                return
            }

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
                    text: "Failed to connect to gRPC server on port \(currentPort); retrying on port \(newPort)…",
                    source: "garage-grpc"
                ))
                self.port = newPort
            } else {
                status = .failed(GarageGRPCError.startupTimeout.localizedDescription)
                throw GarageGRPCError.startupTimeout
            }
        }
    }

    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        isStopping = true
        cleanupChannel()
        runner.terminate()
        for _ in 0..<50 where runner.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        status = .stopped
    }

    private func cleanupChannel() {
        if let channel = self.channel as? ClientConnection {
            _ = channel.close()
        }
        self.channel = nil
        try? group?.syncShutdownGracefully()
        group = nil
    }

    private var isFailed: Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    private static func randomPort(excluding: Set<Int>) -> Int {
        var port: Int
        repeat {
            port = Int.random(in: 49152...65535)
        } while excluding.contains(port)
        return port
    }

    private func getOrCreateChannel() -> GRPCChannel {
        if let channel = self.channel {
            return channel
        }
        let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
        self.group = group
        let connection = ClientConnection.insecure(group: group)
            .connect(host: host, port: port)
        self.channel = connection
        return connection
    }

    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !runner.isRunning {
                return false
            }
            do {
                let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel())
                var pingReq = Garage_PingRequest()
                pingReq.message = "healthcheck"
                let callOptions = CallOptions(timeLimit: .timeout(.milliseconds(500)))
                let response = try await client.ping(pingReq, callOptions: callOptions)
                if !response.message.isEmpty {
                    return true
                }
            } catch {
                cleanupChannel()
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }

    func search(
        query: String,
        mode: String = "hybrid",
        model: String? = nil,
        limit: Int = 10,
        corpusClasses: [String] = [],
        trustTiers: [String] = [],
        sources: [String] = [],
        author: String? = nil,
        full: Bool = false
    ) async throws -> Garage_SearchResponse {
        if status != .running {
            try await start()
        }

        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel())
        var request = Garage_SearchRequest()
        request.query = query
        request.mode = mode
        if let model = model, !model.isEmpty {
            request.model = model
        }
        request.limit = Int32(limit)
        if !corpusClasses.isEmpty {
            request.corpusClasses = corpusClasses
        }
        if !trustTiers.isEmpty {
            request.trustTiers = trustTiers
        }
        if !sources.isEmpty {
            request.sources = sources
        }
        if let author = author, !author.isEmpty {
            request.author = author
        }
        request.full = full

        let callOptions = CallOptions(timeLimit: .timeout(.seconds(30)))
        do {
            let response = try await client.search(request, callOptions: callOptions)
            return response
        } catch {
            throw GarageGRPCError.searchFailed(error.localizedDescription)
        }
    }
}
