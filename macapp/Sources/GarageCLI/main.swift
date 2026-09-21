import Foundation
import Darwin
import OSLog
import PythonKit
import PythonXPCService

private let cliLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag.cli", category: "GarageCLI")

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

/// Starts the isolated interpreter (PyConfig API) with `home`, stdlib, `lib-dynload` and `site-packages` taken
/// from `<Garage.app>/Contents/Resources/site-python`, exactly like the XPC services do.
private func setupPythonEnvironment() -> Bool {
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // Garage.app/Contents/MacOS/garage -> Garage.app
    let bundleURL = execURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let runtime = GaragePythonRuntime.shared
    if bundleURL.pathExtension == "app" {
        runtime.setAppBundle(url: bundleURL)
    }
    switch runtime.initializeIfNeeded() {
    case .success(let env):
        if ProcessInfo.processInfo.environment["GARAGE_DEBUG"] != nil || CommandLine.arguments.contains("--debug") {
            fputs("[GARAGE_CLI] Python home: \(env.home.path)\n", stderr)
        }
        return true
    case .failure(let error):
        fputs("Error starting embedded Python: \(error.localizedDescription)\n", stderr)
        return false
    }
}

private func runCLI() {
    CLIOutputCapturer.shared.start()
    defer {
        CLIOutputCapturer.shared.flush()
    }
    guard setupPythonEnvironment() else {
        CLIOutputCapturer.shared.flush()
        exit(1)
    }

    do {
        try GaragePythonRuntime.shared.withGIL {
            let sys = try Python.attemptImport("sys")

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
            // Use the throwing call so Python exceptions surface as errors instead of PythonKit's `try!` trap.
            let exitCode = Int(try cliModule.main_cli.throwing.dynamicallyCall(withArguments: [])) ?? 0
            CLIOutputCapturer.shared.flush()
            exit(Int32(exitCode))
        }
    } catch {
        // Traceback formatting and any other Python access must happen with the GIL held.
        _ = try? GaragePythonRuntime.shared.withGIL {
            fputs("Error executing garage CLI: \(GaragePythonRuntime.describe(error))\n", stderr)
            if let sys = try? Python.attemptImport("sys") {
                fputs("[GARAGE_CLI] Python sys.path at failure: \(sys.path)\n", stderr)
            }
        }
        CLIOutputCapturer.shared.flush()
        exit(1)
    }
}

runCLI()
