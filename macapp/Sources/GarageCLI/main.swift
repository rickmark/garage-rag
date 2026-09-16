import Foundation
import Darwin
import OSLog
#if canImport(PythonKit)
import PythonKit
#endif

private let cliLogger = Logger(subsystem: "me.rickmark.garage", category: "GarageCLI")

private final class CLIOutputCapturer {
    static let shared = CLIOutputCapturer()
    private var origStdout: Int32 = -1
    private var origStderr: Int32 = -1
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let lock = NSLock()

    func start() {
        origStdout = dup(STDOUT_FILENO)
        origStderr = dup(STDERR_FILENO)

        let outPipe = Pipe()
        let errPipe = Pipe()
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        fflush(stdout)
        fflush(stderr)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let outOrig = origStdout
        let errOrig = origStderr

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if outOrig >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(outOrig, base, data.count)
                    }
                }
            }
            self?.process(data: data, isStderr: false)
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if errOrig >= 0 {
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        _ = write(errOrig, base, data.count)
                    }
                }
            }
            self?.process(data: data, isStderr: true)
        }
    }

    private func process(data: Data, isStderr: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStderr {
            stderrBuffer.append(data)
            while let range = stderrBuffer.firstRange(of: Data([0x0A])) {
                let lineData = stderrBuffer.subdata(in: stderrBuffer.startIndex..<range.lowerBound)
                stderrBuffer.removeSubrange(stderrBuffer.startIndex..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cliLogger.error("\(line, privacy: .public)")
                }
            }
        } else {
            stdoutBuffer.append(data)
            while let range = stdoutBuffer.firstRange(of: Data([0x0A])) {
                let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
                if let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cliLogger.info("\(line, privacy: .public)")
                }
            }
        }
    }

    func flush() {
        fflush(stdout)
        fflush(stderr)
        lock.lock()
        defer { lock.unlock() }
        if !stdoutBuffer.isEmpty, let line = String(data: stdoutBuffer, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cliLogger.info("\(line, privacy: .public)")
            stdoutBuffer.removeAll()
        }
        if !stderrBuffer.isEmpty, let line = String(data: stderrBuffer, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cliLogger.error("\(line, privacy: .public)")
            stderrBuffer.removeAll()
        }
    }
}

private func setupPostgresEnvironment() {
    var candidatePaths: [String] = []
    if let envPath = ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"],
       FileManager.default.fileExists(atPath: envPath) {
        candidatePaths.append(envPath)
    }

    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    // 2. Inside .app bundle (Contents/Resources/postgres/lib/libpq.dylib)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.5.dylib").path)

    // 4. Bundle.main resourceURL
    if let resourceURL = Bundle.main.resourceURL {
        candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.dylib").path)
        candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
    }



    for path in candidatePaths {
        if FileManager.default.fileExists(atPath: path) {
            setenv("GARAGE_LIBPQ_PATH", path, 1)
            let libDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            setenv("DYLD_FALLBACK_LIBRARY_PATH", libDir, 1)
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
            break
        }
    }
}

private func setupPythonEnvironment() {
    if let envPath = ProcessInfo.processInfo.environment["PYTHON_LIBRARY"],
       FileManager.default.fileExists(atPath: envPath) {
        return
    }

    var candidatePaths: [String] = []
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    // 2. Inside .app bundle (Contents/Frameworks/Python.framework)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)

    for path in candidatePaths {
        if FileManager.default.fileExists(atPath: path) {
            let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL)
            if let handle = handle {
                dlclose(handle)
                setenv("PYTHON_LIBRARY", path, 1)
                var current = URL(fileURLWithPath: path)
                while current.path != "/" && current.pathExtension != "framework" {
                    current = current.deletingLastPathComponent()
                }
                if current.pathExtension == "framework" {
                    let frameworkContainerDir = current.deletingLastPathComponent().path
                    setenv("DYLD_FALLBACK_FRAMEWORK_PATH", frameworkContainerDir, 1)
                    setenv("DYLD_FRAMEWORK_PATH", frameworkContainerDir, 1)
                }
                _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
                break
            }
        }
    }
}

private func runCLI() {
    CLIOutputCapturer.shared.start()
    defer {
        CLIOutputCapturer.shared.flush()
    }
    setupPostgresEnvironment()
    setupPythonEnvironment()
    #if canImport(PythonKit)
    do {
        try PythonLibrary.loadLibrary()
    } catch {
        fputs("Error: Failed to load Python runtime library: \(error.localizedDescription)\n", stderr)
        CLIOutputCapturer.shared.flush()
        exit(1)
    }

    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    do {
        let sys = try Python.attemptImport("sys")
        let pythonLibCandidates = [
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
        ]

        for libURL in pythonLibCandidates {
            if FileManager.default.fileExists(atPath: libURL.path) {
                sys.path.insert(0, libURL.path)
            }
        }

        let sitePackagesCandidates = [
            bundleURL.appendingPathComponent("Contents/Resources/site-packages"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
        ]

        for spURL in sitePackagesCandidates {
            if FileManager.default.fileExists(atPath: spURL.path) {
                sys.path.insert(0, spURL.path)
            }
        }

        // Set sys.argv
        sys.argv = PythonObject(CommandLine.arguments)

        // Ensure stdout, stderr, and stdin streams are handed to Python
        do {
            let io = try Python.attemptImport("io")
            if sys.stdin == Python.None || Bool(Python.hasattr(sys.stdin, "read")) != true {
                let stdinObj = io.open(0, mode: "r", encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdin = stdinObj
                sys.__stdin__ = stdinObj
            }
            if sys.stdout == Python.None || Bool(Python.hasattr(sys.stdout, "write")) != true {
                let stdoutObj = io.open(1, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stdout = stdoutObj
                sys.__stdout__ = stdoutObj
            }
            if sys.stderr == Python.None || Bool(Python.hasattr(sys.stderr, "write")) != true {
                let stderrObj = io.open(2, mode: "w", buffering: 1, encoding: "utf-8", errors: "replace", closefd: false)
                sys.stderr = stderrObj
                sys.__stderr__ = stderrObj
            }
        } catch {
            fputs("Warning: Could not configure standard streams for Python: \(error)\n", stderr)
        }

        do {
            let _ = try Python.attemptImport("site")
        } catch {
            fputs("Warning: Could not import site module: \(error)\n", stderr)
        }

        if ProcessInfo.processInfo.environment["GARAGE_DEBUG"] != nil || CommandLine.arguments.contains("--debug") {
            fputs("[GARAGE_CLI] Dynamic Python: \(ProcessInfo.processInfo.environment["PYTHON_LIBRARY"] ?? "default")\n", stderr)
            fputs("[GARAGE_CLI] Dynamic Postgres: \(ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"] ?? "default")\n", stderr)
            fputs("[GARAGE_CLI] Python sys.path: \(sys.path)\n", stderr)
        }

        let cliModule: PythonObject
        do {
            cliModule = try Python.attemptImport("garage_rag.cli")
        } catch {
            if let tb = try? Python.attemptImport("traceback") {
                _ = tb.print_exc()
            }
            fputs("Error executing garage CLI: \(error)\n", stderr)
            fputs("[GARAGE_CLI] Python sys.path at failure: \(sys.path)\n", stderr)
            CLIOutputCapturer.shared.flush()
            exit(1)
        }
        let exitCode = Int(cliModule.main_cli()) ?? 0
        CLIOutputCapturer.shared.flush()
        exit(Int32(exitCode))
    } catch {
        if let tb = try? Python.attemptImport("traceback") {
            _ = tb.print_exc()
        }
        fputs("Error executing garage CLI: \(error)\n", stderr)
        if let sys = try? Python.attemptImport("sys") {
            fputs("[GARAGE_CLI] Python sys.path at failure: \(sys.path)\n", stderr)
        }
        CLIOutputCapturer.shared.flush()
        exit(1)
    }
    #else
    fputs("Error: PythonKit not available\n", stderr)
    CLIOutputCapturer.shared.flush()
    exit(1)
    #endif
}

runCLI()
