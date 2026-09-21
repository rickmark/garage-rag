import Foundation
import Darwin
import OSLog
import GaragePythonEmbed
import PythonKit
import PythonXPCService_protocol

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GaragePythonRuntime")

/// Describes the on-disk layout of the isolated Python environment shipped inside the application bundle.
///
/// Layout (relative to `<App>.app/Contents/Resources`):
/// ```
/// site-python/                 <- python stdlib (os.py, ...) == PyConfig.home / stdlib_dir
/// site-python/lib-dynload/     <- compiled stdlib extension modules
/// site-python/site-packages/   <- third-party packages + garage_rag
/// ```
public struct GaragePythonEnvironment: Equatable, Sendable {
    public static let sitePythonDirectoryName = "site-python"
    public static let libDynloadDirectoryName = "lib-dynload"
    public static let sitePackagesDirectoryName = "site-packages"

    /// The `.app` bundle the environment was resolved from (if any).
    public let appBundleURL: URL?
    /// `PyConfig.home`: the directory that holds the standard library.
    public let home: URL
    public let stdlibDir: URL
    public let libDynloadDir: URL
    public let sitePackagesDir: URL
    /// Additional `sys.path` entries appended after site-packages.
    public let extraSearchPaths: [URL]

    public init(appBundleURL: URL?, sitePythonURL: URL, extraSearchPaths: [URL] = []) {
        self.appBundleURL = appBundleURL
        self.home = sitePythonURL
        self.stdlibDir = sitePythonURL
        self.libDynloadDir = sitePythonURL.appendingPathComponent(Self.libDynloadDirectoryName, isDirectory: true)
        self.sitePackagesDir = sitePythonURL.appendingPathComponent(Self.sitePackagesDirectoryName, isDirectory: true)
        self.extraSearchPaths = extraSearchPaths
    }

    /// Ordered `sys.path` as it will be handed to the interpreter.
    public var searchPaths: [URL] {
        [stdlibDir, libDynloadDir, sitePackagesDir] + extraSearchPaths
    }

    /// Returns human readable problems with this layout (missing landmarks). Empty means the layout is valid.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if !fm.fileExists(atPath: home.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("Python home directory is missing: \(home.path)")
            return problems
        }
        let osLandmark = stdlibDir.appendingPathComponent("os.py").path
        if !fm.fileExists(atPath: osLandmark) {
            problems.append("Standard library landmark 'os.py' not found in \(stdlibDir.path)")
        }
        if !fm.fileExists(atPath: libDynloadDir.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("lib-dynload directory is missing: \(libDynloadDir.path)")
        }
        if !fm.fileExists(atPath: sitePackagesDir.path, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("site-packages directory is missing: \(sitePackagesDir.path)")
        }
        return problems
    }
}

/// Errors raised while resolving or starting the embedded interpreter.
public enum GaragePythonRuntimeError: Error, LocalizedError, Equatable {
    case appBundleNotResolved(String)
    case invalidEnvironment([String])
    case initializationFailed(code: Int, message: String)
    case notInitialized
    case fileHandleUnresolvable(String)

    public var errorDescription: String? {
        switch self {
        case .appBundleNotResolved(let detail):
            return "Unable to resolve the Garage application bundle: \(detail)"
        case .invalidEnvironment(let problems):
            return "Bundled Python environment is incomplete:\n  - " + problems.joined(separator: "\n  - ")
        case .initializationFailed(let code, let message):
            return "Py_InitializeFromConfig failed (code \(code)): \(message)"
        case .notInitialized:
            return "The embedded Python interpreter has not been initialized"
        case .fileHandleUnresolvable(let detail):
            return "Unable to resolve a path from the provided file handle: \(detail)"
        }
    }
}

/// Owns the single embedded CPython interpreter of an XPC service.
///
/// Responsibilities:
/// - resolve the isolated environment (`Resources/site-python`) relative to the main application bundle,
///   which may be provided explicitly (URL or `FileHandle`) by the host application or inferred from the
///   location of the XPC bundle;
/// - start the interpreter through the PyConfig API (isolated mode, explicit `home` and `sys.path`);
/// - manage the GIL for host → Python calls so that Python threads (gRPC servers, thread pools)
///   keep running while Swift code is idle.
///
/// Rule for callers: create, use **and release** `PythonObject` values inside a single `withGIL` scope.
/// PythonKit decrements reference counts when a `PythonObject` is destroyed, which must happen with the GIL held,
/// so avoid storing `PythonObject`s in properties that may be released from arbitrary threads (store them only
/// where the release also happens inside `withGIL`, as `GarageGRPCManagedServer` does).
public final class GaragePythonRuntime: @unchecked Sendable {
    public static let shared = GaragePythonRuntime()

    public enum State: Equatable, Sendable {
        case notStarted
        case starting
        case ready
        case failed(String)

        public var name: String {
            switch self {
            case .notStarted: return "notStarted"
            case .starting: return "starting"
            case .ready: return "ready"
            case .failed: return "failed"
            }
        }

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private let stateLock = NSRecursiveLock()
    private var _state: State = .notStarted
    private var _environment: GaragePythonEnvironment?
    private var _explicitAppBundleURL: URL?
    private var _securityScopedURL: URL?
    private var _appBundleFileHandle: FileHandle?
    private var _initializationMs: Double?
    private var _pythonVersion: String?
    private var _sysPath: [String] = []
    private var _libpqPath: String?
    private var _libpqError: String?
    private var _libpqHandle: UnsafeMutableRawPointer?

    /// Serial queue that owns interpreter initialization (exactly one `Py_InitializeFromConfig` per process).
    private let pythonQueue = DispatchQueue(label: "me.rickmark.garage-rag.python-runtime", qos: .userInitiated)
    private let pythonQueueKey = DispatchSpecificKey<Bool>()

    /// Environment variable that allows overriding the `site-python` location during development / testing.
    public static let sitePythonOverrideEnvironmentKey = "GARAGE_SITE_PYTHON"

    /// Environment variable naming the `libpq.dylib` psycopg must use. Set by the host app for child processes
    /// and exported by the runtime itself once the bundled copy has been resolved, so `garage_rag` (and the
    /// ctypes hook installed at start-up) always point psycopg at the signed library inside the bundle.
    public static let libpqPathEnvironmentKey = "GARAGE_LIBPQ_PATH"

    public init() {
        pythonQueue.setSpecific(key: pythonQueueKey, value: true)
    }

    // MARK: - State

    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    public var environment: GaragePythonEnvironment? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _environment
    }

    public var isReady: Bool { state.isReady }

    public var pythonVersion: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _pythonVersion
    }

    /// The app bundle URL currently used as the basis for path resolution (explicit or inferred).
    public var appBundleURL: URL? {
        stateLock.lock()
        let explicit = _explicitAppBundleURL
        stateLock.unlock()
        return explicit ?? Self.inferAppBundleURL()
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
    }

    // MARK: - App bundle references

    /// Registers the main application bundle URL as the basis for Python path resolution and extends the
    /// sandbox with security scoped access when the URL carries a scope.
    @discardableResult
    public func setAppBundle(url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue else {
            logger.error("setAppBundle(url:) ignored: '\(standardized.path, privacy: .public)' is not a directory")
            return false
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = _explicitAppBundleURL, existing == standardized {
            return true
        }
        if let scoped = _securityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            _securityScopedURL = nil
        }
        if standardized.startAccessingSecurityScopedResource() {
            _securityScopedURL = standardized
            logger.info("Security scoped access granted for app bundle '\(standardized.path, privacy: .public)'")
        }
        _explicitAppBundleURL = standardized
        logger.info("App bundle reference set to '\(standardized.path, privacy: .public)'")
        return true
    }

    /// Registers the main application bundle from an open directory descriptor. The path is recovered with
    /// `fcntl(F_GETPATH)`; the descriptor is retained for the lifetime of the runtime so the underlying vnode
    /// stays reachable even if the bundle is moved.
    public func setAppBundle(fileHandle: FileHandle) throws {
        let fd = fileHandle.fileDescriptor
        guard fd >= 0 else {
            throw GaragePythonRuntimeError.fileHandleUnresolvable("invalid file descriptor")
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else {
            let err = String(cString: strerror(errno))
            throw GaragePythonRuntimeError.fileHandleUnresolvable("fcntl(F_GETPATH) failed: \(err)")
        }
        let path = String(cString: buffer)
        guard !path.isEmpty else {
            throw GaragePythonRuntimeError.fileHandleUnresolvable("fcntl(F_GETPATH) returned an empty path")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard setAppBundle(url: url) else {
            throw GaragePythonRuntimeError.fileHandleUnresolvable("'\(path)' is not a directory")
        }
        stateLock.lock()
        _appBundleFileHandle = fileHandle
        stateLock.unlock()
        logger.info("App bundle reference resolved from file handle (fd \(fd, privacy: .public)) -> '\(path, privacy: .public)'")
    }

    /// Walks up from the running bundle (`Garage.app/Contents/XPCServices/X.xpc`) to find the enclosing `.app`.
    public static func inferAppBundleURL(from bundle: Bundle = .main) -> URL? {
        var cursor = bundle.bundleURL.standardizedFileURL
        for _ in 0..<8 {
            if cursor.pathExtension == "app" {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        // Not inside an .app: when running as a plain executable, honour an adjacent Resources folder.
        let exe = bundle.executableURL?.standardizedFileURL ?? bundle.bundleURL
        let candidate = exe.deletingLastPathComponent().deletingLastPathComponent()
        if candidate.pathExtension == "app" {
            return candidate
        }
        return nil
    }

    // MARK: - Environment resolution

    /// Resolves the isolated environment from (in order): `GARAGE_SITE_PYTHON`, the explicitly registered app
    /// bundle, the inferred enclosing `.app`, and finally the XPC bundle's own `Resources`.
    public func resolveEnvironment() throws -> GaragePythonEnvironment {
        let fm = FileManager.default
        var candidates: [(URL?, URL)] = []

        if let override = ProcessInfo.processInfo.environment[Self.sitePythonOverrideEnvironmentKey], !override.isEmpty {
            candidates.append((nil, URL(fileURLWithPath: override, isDirectory: true)))
        }

        stateLock.lock()
        let explicit = _explicitAppBundleURL
        stateLock.unlock()

        var bundleCandidates: [URL] = []
        if let explicit = explicit { bundleCandidates.append(explicit) }
        if let inferred = Self.inferAppBundleURL(), !bundleCandidates.contains(inferred) { bundleCandidates.append(inferred) }

        for bundleURL in bundleCandidates {
            let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
            candidates.append((bundleURL, resources.appendingPathComponent(GaragePythonEnvironment.sitePythonDirectoryName, isDirectory: true)))
        }

        if let ownResources = Bundle.main.resourceURL {
            candidates.append((nil, ownResources.appendingPathComponent(GaragePythonEnvironment.sitePythonDirectoryName, isDirectory: true)))
        }

        var problems: [String] = []
        for (bundleURL, sitePython) in candidates {
            let env = GaragePythonEnvironment(appBundleURL: bundleURL, sitePythonURL: sitePython.standardizedFileURL)
            let envProblems = env.validationProblems()
            if envProblems.isEmpty {
                logger.info("Resolved Python environment: home='\(env.home.path, privacy: .public)' (app bundle: \(bundleURL?.path ?? "n/a", privacy: .public))")
                return env
            }
            if fm.fileExists(atPath: sitePython.path) {
                problems.append(contentsOf: envProblems)
            } else {
                problems.append("No site-python directory at \(sitePython.path)")
            }
        }

        if bundleCandidates.isEmpty {
            throw GaragePythonRuntimeError.appBundleNotResolved("no app bundle reference was provided and the XPC bundle is not nested inside an .app (\(Bundle.main.bundleURL.path))")
        }
        throw GaragePythonRuntimeError.invalidEnvironment(problems)
    }

    // MARK: - libpq

    /// Path of the `libpq.dylib` that was loaded into this process for psycopg (nil when unavailable).
    public var libpqPath: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _libpqPath
    }

    /// Locates the PostgreSQL client library shipped with the application.
    ///
    /// Order: `GARAGE_LIBPQ_PATH`, `<App>/Contents/Frameworks/libpq.dylib`, the legacy
    /// `<App>/Contents/Resources/postgres/lib/libpq.dylib`, then the running bundle's own `Frameworks` folder.
    /// Only files inside the (signed) bundle are considered; system or Homebrew copies are never used because
    /// library validation rejects binaries signed by a different Team ID.
    public func resolveLibpqURL(appBundleURL: URL?) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment[Self.libpqPathEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundle = appBundleURL {
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            candidates.append(contents.appendingPathComponent("Frameworks/libpq.dylib"))
            candidates.append(contents.appendingPathComponent("Resources/postgres/lib/libpq.dylib"))
            candidates.append(contents.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib"))
        }
        if let own = Bundle.main.privateFrameworksURL {
            candidates.append(own.appendingPathComponent("libpq.dylib"))
        }

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: standardized.path, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    /// Loads the bundled libpq into the process (`dlopen`, `RTLD_GLOBAL`) and exports its location through
    /// `GARAGE_LIBPQ_PATH`. Loading it here, from Swift, surfaces code-signing / library-validation problems as a
    /// clear diagnostic instead of psycopg's generic "no pq wrapper available" failure, and guarantees the copy
    /// psycopg binds to via ctypes is the one inside the bundle.
    private func loadBundledLibpq(appBundleURL: URL?) {
        guard let url = resolveLibpqURL(appBundleURL: appBundleURL) else {
            let searched = appBundleURL.map { "\($0.path)/Contents/Frameworks, \($0.path)/Contents/Resources/postgres/lib" } ?? "no app bundle resolved"
            let message = "libpq.dylib not found (searched: \(searched)); psycopg will fall back to its own search"
            logger.warning("\(message, privacy: .public)")
            stateLock.lock()
            _libpqPath = nil
            _libpqError = message
            stateLock.unlock()
            return
        }

        var loadError: String?
        stateLock.lock()
        var handle = _libpqHandle
        stateLock.unlock()
        if handle == nil {
            handle = dlopen(url.path, RTLD_NOW | RTLD_GLOBAL)
            if handle == nil {
                loadError = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            }
        }

        if let loadError = loadError {
            logger.error("Failed to load bundled libpq at '\(url.path, privacy: .public)': \(loadError, privacy: .public)")
        } else {
            // Point psycopg (and any subprocess) at the exact library we just loaded.
            setenv(Self.libpqPathEnvironmentKey, url.path, 1)
            logger.info("Loaded bundled libpq from '\(url.path, privacy: .public)'")
        }

        stateLock.lock()
        _libpqHandle = handle
        _libpqPath = loadError == nil ? url.path : nil
        _libpqError = loadError
        stateLock.unlock()
    }

    /// Python source executed right after interpreter start-up. It teaches `ctypes.util.find_library` about the
    /// bundled libpq so psycopg's pure Python implementation (`psycopg.pq.misc.find_libpq_full_path`) resolves
    /// it instead of probing `pg_config` / Homebrew. Mirrors `garage_rag.libpq.configure()` for the case where
    /// `garage_rag` itself is missing or psycopg gets imported before it.
    static let libpqBootstrapSource = """
    import os as _os, ctypes.util as _ctypes_util
    _path = _os.environ.get("GARAGE_LIBPQ_PATH")
    if _path and _os.path.isfile(_path) and getattr(_ctypes_util, "_garage_libpq_path", None) != _path:
        _original = getattr(_ctypes_util, "_garage_original_find_library", _ctypes_util.find_library)
        def _garage_find_library(name, _original=_original, _path=_path):
            if name in ("pq", "libpq", "libpq.dylib", "libpq.5.dylib", "libpq.5"):
                return _path
            return _original(name)
        _ctypes_util._garage_original_find_library = _original
        _ctypes_util._garage_libpq_path = _path
        _ctypes_util.find_library = _garage_find_library
    """

    // MARK: - Initialization

    /// Initializes the interpreter once. Safe to call repeatedly from any thread; subsequent calls return the
    /// cached result. Initialization happens on the runtime queue.
    @discardableResult
    public func initializeIfNeeded() -> Result<GaragePythonEnvironment, Error> {
        stateLock.lock()
        if case .ready = _state, let env = _environment {
            stateLock.unlock()
            return .success(env)
        }
        if case .failed(let message) = _state, GaragePythonEmbedIsInitialized() {
            // Interpreter exists but post-init checks failed; do not try to start a second interpreter.
            stateLock.unlock()
            return .failure(GaragePythonRuntimeError.initializationFailed(code: -1, message: message))
        }
        stateLock.unlock()

        return runOnPythonQueueSync { [self] in
            // Py_InitializeFromConfig imports `site`/`encodings` etc.; never do that on a 512 KB GCD stack.
            (try? onLargeStack { self.performInitialization() }) ?? .failure(GaragePythonRuntimeError.notInitialized)
        }
    }

    private func performInitialization() -> Result<GaragePythonEnvironment, Error> {
        stateLock.lock()
        if case .ready = _state, let env = _environment {
            stateLock.unlock()
            return .success(env)
        }
        _state = .starting
        stateLock.unlock()

        let start = CFAbsoluteTimeGetCurrent()
        let environment: GaragePythonEnvironment
        do {
            environment = try resolveEnvironment()
        } catch {
            let message = error.localizedDescription
            logger.error("Python environment resolution failed: \(message, privacy: .public)")
            setState(.failed(message))
            return .failure(error)
        }

        // libpq must be resolved (and GARAGE_LIBPQ_PATH exported) before the interpreter snapshots os.environ.
        loadBundledLibpq(appBundleURL: environment.appBundleURL ?? appBundleURL)

        if GaragePythonEmbedIsInitialized() {
            logger.warning("Interpreter already initialized before GaragePythonRuntime; adopting existing interpreter")
        } else {
            var options = GaragePythonEmbedOptionsDefault()
            options.disableBytecodeWriting = true
            options.skipSignalHandlers = true
            options.importSite = true
            options.releaseGILAfterInit = true
            options.verbose = ProcessInfo.processInfo.environment["GARAGE_PYTHON_VERBOSE"] != nil

            let extraPaths = environment.extraSearchPaths.map { $0.path }
            let programName = Bundle.main.executableURL?.path ?? "python3"

            var errorBuffer = [CChar](repeating: 0, count: 2048)
            let result: GaragePythonEmbedResult = withCStrings([environment.home.path, environment.stdlibDir.path, environment.libDynloadDir.path, environment.sitePackagesDir.path, programName] + extraPaths) { pointers in
                options.home = pointers[0]
                options.stdlibDir = pointers[1]
                options.platStdlibDir = pointers[2]
                options.programName = pointers[4]
                // site-packages first, then any extra search paths, NULL terminated.
                var extra: [UnsafePointer<CChar>?] = [pointers[3]]
                extra.append(contentsOf: pointers.dropFirst(5).map { Optional($0) })
                extra.append(nil)
                return extra.withUnsafeBufferPointer { buffer -> GaragePythonEmbedResult in
                    options.extraSearchPaths = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    return GaragePythonEmbedInitialize(&options, &errorBuffer, errorBuffer.count)
                }
            }

            if result != GaragePythonEmbedResultOK && result != GaragePythonEmbedResultAlreadyInitialized {
                let message = String(cString: errorBuffer)
                let error = GaragePythonRuntimeError.initializationFailed(code: Int(result.rawValue), message: message)
                logger.error("Py_InitializeFromConfig failed: \(message, privacy: .public)")
                setState(.failed(error.localizedDescription))
                return .failure(error)
            }
        }

        // Post-init: capture version / sys.path and make PythonKit's wrapper initialize under the GIL.
        var version = ""
        var sysPath: [String] = []
        var postInitError: String?
        try? withGILUnchecked {
            version = String(cString: GaragePythonEmbedRuntimeVersion())
            do {
                let sys = try Python.attemptImport("sys")
                sysPath = Array(sys.path).compactMap { String($0) }
                // Make sure stdout/stderr exist so Python logging works even when launched by launchd
                // without a controlling terminal.
                let io = try Python.attemptImport("io")
                if sys.stdout == Python.None {
                    sys.stdout = io.open(1, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                }
                if sys.stderr == Python.None {
                    sys.stderr = io.open(2, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                }
                // Route psycopg's libpq lookup to the bundled library.
                let builtins = try Python.attemptImport("builtins")
                let namespace = Python.dict()
                _ = try builtins.exec.throwing.dynamicallyCall(withArguments: [Self.libpqBootstrapSource, namespace])
            } catch {
                postInitError = Self.describe(error)
            }
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        stateLock.lock()
        _environment = environment
        _pythonVersion = version
        _sysPath = sysPath
        _initializationMs = elapsedMs
        if let postInitError = postInitError {
            _state = .failed("Interpreter started but post-initialization checks failed: \(postInitError)")
            stateLock.unlock()
            logger.error("Python post-initialization failed: \(postInitError, privacy: .public)")
            return .failure(GaragePythonRuntimeError.initializationFailed(code: -1, message: postInitError))
        }
        _state = .ready
        stateLock.unlock()

        logger.info("Embedded Python \(version, privacy: .public) ready in \(String(format: "%.1f", elapsedMs), privacy: .public)ms; home='\(environment.home.path, privacy: .public)'")
        for (idx, entry) in sysPath.enumerated() {
            logger.debug("sys.path[\(idx, privacy: .public)] = \(entry, privacy: .public)")
        }
        return .success(environment)
    }

    // MARK: - Execution

    private var isOnPythonQueue: Bool {
        DispatchQueue.getSpecific(key: pythonQueueKey) == true
    }

    private func runOnPythonQueueSync<T>(_ body: () -> T) -> T {
        if isOnPythonQueue {
            return body()
        }
        return pythonQueue.sync(execute: body)
    }

    // MARK: - Large stack execution

    /// Stack size for threads that run Python code. CPython on macOS assumes the 8 MB main-thread stack (its own
    /// threads get 16 MB); GCD worker threads only have 512 KB, which deep interpreter recursion
    /// (`slot_tp_new` → `_PyEval_EvalFrameDefault` → …) overruns within a few hundred frames and dies with
    /// `SIGBUS: KERN_PROTECTION_FAILURE` in the stack guard page.
    public static let pythonThreadStackSize = 16 * 1024 * 1024
    /// Threads with less stack than this are never allowed to execute Python.
    public static let minimumPythonStackSize = 4 * 1024 * 1024

    /// True when the calling thread's stack is large enough to run the interpreter.
    public static var currentThreadHasLargeStack: Bool {
        pthread_get_stacksize_np(pthread_self()) >= minimumPythonStackSize
    }

    /// Runs `body` synchronously on a freshly created thread with a `pythonThreadStackSize` stack.
    private func hopToLargeStack<T>(_ body: () -> T) -> T {
        var result: T?
        withoutActuallyEscaping(body) { escapable in
            // pthread + join keeps the closure strictly scoped (an NSThread would retain it past this block).
            var work: () -> Void = { result = escapable() }
            withUnsafeMutablePointer(to: &work) { workPointer in
                var attributes = pthread_attr_t()
                pthread_attr_init(&attributes)
                pthread_attr_setstacksize(&attributes, Self.pythonThreadStackSize)
                pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)
                var thread: pthread_t?
                let rc = pthread_create(&thread, &attributes, { raw in
                    pthread_setname_np("me.rickmark.garage-rag.python-stack")
                    GarageXPCCrashHandler.installAlternateSignalStackForCurrentThread()
                    raw.assumingMemoryBound(to: (() -> Void).self).pointee()
                    return nil
                }, UnsafeMutableRawPointer(workPointer))
                pthread_attr_destroy(&attributes)
                if rc == 0, let thread = thread {
                    pthread_join(thread, nil)
                } else {
                    logger.error("pthread_create for Python stack failed (\(rc)); running on the caller's stack")
                    workPointer.pointee()
                }
            }
        }
        return result!
    }

    /// Guarantees `body` executes on a thread whose stack is big enough for CPython, hopping synchronously to a
    /// dedicated large-stack thread when the caller is a GCD worker. No-op on the main thread, on Python-created
    /// threads and on threads already created by this helper.
    public func onLargeStack<T>(_ body: () throws -> T) throws -> T {
        if Self.currentThreadHasLargeStack {
            return try body()
        }
        let outcome: Result<T, Error> = hopToLargeStack { Result { try body() } }
        return try outcome.get()
    }

    /// Acquires the GIL for the duration of `body` (on a large-stack thread) without checking runtime state.
    private func withGILUnchecked<T>(_ body: () throws -> T) throws -> T {
        try onLargeStack {
            let token = GaragePythonEmbedAcquireGIL()
            defer { GaragePythonEmbedReleaseGIL(token) }
            return try body()
        }
    }

    /// Executes `body` on the calling thread with the GIL held (`PyGILState_Ensure`/`Release`). Every use of
    /// PythonKit from Swift must go through this (or `perform`/`run`) so the GIL is owned by the calling thread
    /// and released again when Swift is done, letting Python's own threads make progress.
    ///
    /// Calls are *not* serialized: CPython's GIL arbitrates between concurrent callers, so a long running
    /// operation (for example an ingest run) does not block status queries, self tests or cancellation
    /// requests issued from other threads. Nested calls on the same thread are allowed.
    public func withGIL<T>(_ body: () throws -> T) throws -> T {
        guard isReady || GaragePythonEmbedIsInitialized() else {
            if case .failed(let message) = state {
                throw GaragePythonRuntimeError.initializationFailed(code: -1, message: message)
            }
            throw GaragePythonRuntimeError.notInitialized
        }
        return try withGILUnchecked(body)
    }

    /// Background queue for fire-and-forget Python work (`perform`/`run`). Concurrent so that independent
    /// requests do not queue behind each other; the GIL provides the actual mutual exclusion.
    private let workQueue = DispatchQueue(label: "me.rickmark.garage-rag.python-work", qos: .userInitiated, attributes: .concurrent)

    /// Schedules `body` on a background thread with the GIL held.
    public func perform(_ body: @escaping () -> Void) {
        workQueue.async { [self] in
            guard GaragePythonEmbedIsInitialized() else {
                logger.error("perform() dropped: interpreter not initialized")
                return
            }
            try? withGILUnchecked(body)
        }
    }

    /// Async/await convenience: runs `body` on a background thread with the GIL held.
    public func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [self] in
                do {
                    let value = try withGIL(body)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Imports a module while holding the GIL. Convenience for diagnostics.
    public func importModule(_ name: String) throws -> PythonObject {
        try withGIL { try Python.attemptImport(name) }
    }

    // MARK: - Diagnostics

    /// Formats a Swift/PythonKit error including the Python traceback where available.
    public static func describe(_ error: Error) -> String {
        if let pyError = error as? PythonError {
            switch pyError {
            case .exception(let value, let traceback):
                var text = "\(value)"
                if let tb = traceback, let tbModule = try? Python.attemptImport("traceback") {
                    let lines = tbModule.format_exception(Python.type(value), value, tb)
                    let joined = Array(lines).compactMap { String($0) }.joined()
                    if !joined.isEmpty { text = joined }
                }
                return text
            default:
                return pyError.description
            }
        }
        return error.localizedDescription
    }

    /// Snapshot for status reporting.
    public func statusSnapshot() -> GarageXPCPythonStatus {
        stateLock.lock()
        let st = _state
        let env = _environment
        let version = _pythonVersion
        let sysPath = _sysPath
        let initMs = _initializationMs
        let libpqPath = _libpqPath
        let libpqError = _libpqError
        stateLock.unlock()

        var errorText: String? = nil
        if case .failed(let message) = st { errorText = message }

        return GarageXPCPythonStatus(
            state: st.name,
            version: version,
            home: env?.home.path,
            stdlibDir: env?.stdlibDir.path,
            libDynloadDir: env?.libDynloadDir.path,
            sitePackagesDir: env?.sitePackagesDir.path,
            sysPath: sysPath,
            error: errorText,
            initializationMs: initMs,
            libpqPath: libpqPath,
            libpqError: libpqError
        )
    }
}

// MARK: - Helpers

/// Calls `body` with stable C string pointers for every element of `strings`.
private func withCStrings<T>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> T) -> T {
    var pointers: [UnsafeMutablePointer<CChar>] = []
    pointers.reserveCapacity(strings.count)
    for s in strings {
        pointers.append(strdup(s))
    }
    defer { pointers.forEach { free($0) } }
    return body(pointers.map { UnsafePointer($0) })
}
