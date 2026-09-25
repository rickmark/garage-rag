import Foundation
import LlamaClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "LlamaModelLoader")

/// Makes sure a model is resident in LlamaXPCService before something needs it, loading it over
/// NSXPC (`ensureModel`) when it is not. Never over the HTTP `/models/load` route.
///
/// - The alias is the model's slug (the `model` Python sends); `LlamaModelResolver` turns it into
///   the downloaded GGUF and the load settings the Models page uses.
/// - A resident alias costs one status call (`/v1/models` over NSXPC, which does not wait for a
///   running inference); nothing is resolved or loaded.
/// - Callers in this process asking for the same alias share one load. Callers in other processes
///   are deduplicated by the service: `ensureModel` checks and loads under the engine lock.
/// - Nothing is ever unloaded here. The engine keeps several models resident (typically the
///   embedding model and the facts model); the Models page's Unload frees them.
public final class LlamaModelLoader: @unchecked Sendable {
    /// What the loader needs from LlamaXPCService; `LlamaClient` in production, a fake in tests.
    public struct Service: Sendable {
        public var residentAliases: @Sendable () async throws -> [String]
        public var ensure: @Sendable (LlamaModelLoadPlan) async throws -> String

        public init(
            residentAliases: @escaping @Sendable () async throws -> [String],
            ensure: @escaping @Sendable (LlamaModelLoadPlan) async throws -> String
        ) {
            self.residentAliases = residentAliases
            self.ensure = ensure
        }

        /// LlamaXPCService over NSXPC. The connection is made again once if the service went away
        /// (a relaunched service answers a fresh connection; it also comes back with no models).
        public static func xpc(makeClient: @escaping @Sendable () -> LlamaClient = { LlamaClient() }) -> Service {
            let box = ClientBox(makeClient: makeClient)
            return Service(
                residentAliases: {
                    try await box.withClient { try await $0.listModels().data.map(\.id) }
                },
                ensure: { plan in
                    try await box.withClient { try await $0.ensureModel(path: plan.path, alias: plan.alias, config: plan.config) }
                }
            )
        }
    }

    public enum Outcome: Equatable, Sendable {
        case alreadyLoaded
        case loaded(message: String)
    }

    private let resolve: @Sendable (String) throws -> LlamaModelLoadPlan
    private let service: Service
    private let inFlight = InFlightLoads()

    public init(
        service: Service,
        resolve: @escaping @Sendable (String) throws -> LlamaModelLoadPlan
    ) {
        self.service = service
        self.resolve = resolve
    }

    /// The loader for this process: LlamaXPCService over NSXPC, models resolved from the catalog
    /// and models folder of the app's data folder.
    public static func standard() -> LlamaModelLoader {
        let resolver = LlamaModelResolver.standard()
        return LlamaModelLoader(service: .xpc(), resolve: { try resolver.resolve(alias: $0) })
    }

    /// Ensures `alias` is resident, loading it when it is not.
    @discardableResult
    public func ensureLoaded(alias: String) async throws -> Outcome {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { throw LlamaModelLoaderError.unknownModel(alias: alias) }

        // A status check failing is not fatal: the ensure call below says whether the service is there.
        if let resident = try? await service.residentAliases(), resident.contains(alias) {
            return .alreadyLoaded
        }
        return try await inFlight.run(alias) { [resolve, service] in
            let plan = try resolve(alias)
            logger.info("Loading \(alias, privacy: .public) on demand from \(plan.path, privacy: .public)")
            do {
                let message = try await service.ensure(plan)
                return .loaded(message: message)
            } catch let error as LlamaModelLoaderError {
                throw error
            } catch {
                throw LlamaModelLoaderError.loadFailed(alias: alias, message: error.localizedDescription)
            }
        }
    }

    /// `ensureLoaded` for a caller that has to block (the C bridge Python calls through ctypes).
    /// Waits at most `timeout` seconds: NSXPC replies have no deadline of their own, and a
    /// multi-gigabyte GGUF can take a while to map.
    public func ensureLoadedBlocking(alias: String, timeout: TimeInterval = 600) -> Result<Outcome, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached { [self] in
            do {
                box.set(.success(try await ensureLoaded(alias: alias)))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(LlamaModelLoaderError.timedOut(alias: alias, seconds: Int(timeout)))
        }
        return box.get() ?? .failure(LlamaModelLoaderError.loadFailed(alias: alias, message: "no result"))
    }
}

/// One load per alias at a time within this process: later callers await the first one's task.
private actor InFlightLoads {
    private var tasks: [String: Task<LlamaModelLoader.Outcome, Error>] = [:]

    func run(
        _ alias: String,
        _ body: @escaping @Sendable () async throws -> LlamaModelLoader.Outcome
    ) async throws -> LlamaModelLoader.Outcome {
        if let existing = tasks[alias] {
            return try await existing.value
        }
        let task = Task { try await body() }
        tasks[alias] = task
        defer { tasks[alias] = nil }
        return try await task.value
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LlamaModelLoader.Outcome, Error>?

    func set(_ value: Result<LlamaModelLoader.Outcome, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<LlamaModelLoader.Outcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// The NSXPC client, made again once when a call finds the service gone.
private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private let makeClient: @Sendable () -> LlamaClient
    private var client: LlamaClient?

    init(makeClient: @escaping @Sendable () -> LlamaClient) {
        self.makeClient = makeClient
    }

    private func current(fresh: Bool) -> LlamaClient {
        lock.lock()
        defer { lock.unlock() }
        if fresh || client == nil {
            client = makeClient()
        }
        return client!
    }

    func withClient<T>(_ body: (LlamaClient) async throws -> T) async throws -> T {
        do {
            return try await body(current(fresh: false))
        } catch LlamaClientError.serviceUnavailable(_) {
            return try await body(current(fresh: true))
        }
    }
}
