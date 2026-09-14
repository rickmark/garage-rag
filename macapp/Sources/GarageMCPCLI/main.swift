import Foundation
import Darwin
#if canImport(PythonKit)
import PythonKit
#endif

private func setupPostgresEnvironment() {
    var candidatePaths: [String] = []
    if let envPath = ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"],
       FileManager.default.fileExists(atPath: envPath) {
        candidatePaths.append(envPath)
    }

    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    // 1. Primary path from Contents/MacOS/garage-mcp: ../../Resources/postgres/lib/libpq.dylib
    candidatePaths.append(execURL.appendingPathComponent("../../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
    candidatePaths.append(execURL.appendingPathComponent("../../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../../Resources/postgres/lib/libpq.dylib").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../../Resources/postgres/lib/libpq.5.dylib").standardizedFileURL.path)

    // 2. Inside .app bundle (Contents/Resources/postgres/lib/libpq.dylib)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.5.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib").path)

    // 3. Standalone / binary relative
    candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.5.dylib").path)

    // 4. Bundle.main resourceURL
    if let resourceURL = Bundle.main.resourceURL {
        candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.dylib").path)
        candidatePaths.append(resourceURL.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
    }

    // 5. System / Homebrew / Installed Garage.app fallbacks
    candidatePaths.append("/Applications/Garage.app/Contents/Resources/postgres/lib/libpq.dylib")
    candidatePaths.append("/Applications/Garage.app/Contents/Resources/postgres/lib/libpq.5.dylib")
    candidatePaths.append("/opt/homebrew/opt/libpq/lib/libpq.dylib")
    candidatePaths.append("/opt/homebrew/opt/libpq/lib/libpq.5.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@18/libpq.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@18/libpq.5.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@17/libpq.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@17/libpq.5.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@16/libpq.dylib")
    candidatePaths.append("/opt/homebrew/lib/postgresql@16/libpq.5.dylib")
    candidatePaths.append("/opt/homebrew/lib/libpq.dylib")
    candidatePaths.append("/opt/homebrew/lib/libpq.5.dylib")
    candidatePaths.append("/usr/local/opt/libpq/lib/libpq.dylib")
    candidatePaths.append("/usr/local/opt/libpq/lib/libpq.5.dylib")
    candidatePaths.append("/usr/local/lib/libpq.dylib")
    candidatePaths.append("/usr/local/lib/libpq.5.dylib")

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

    // 1. Primary path from Contents/MacOS/garage-mcp: ../../Frameworks/Python.framework/Versions/Current/Python
    candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
    candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
    candidatePaths.append(execURL.appendingPathComponent("../../Frameworks/Python.framework/Python").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Python").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/Python").standardizedFileURL.path)
    candidatePaths.append(binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/Python").standardizedFileURL.path)

    // 2. Inside .app bundle (Contents/Frameworks/Python.framework)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Python").path)

    // 3. Standalone CLI binary relative (../Frameworks/Python.framework)
    candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/Current/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/3.13/Python").path)

    // 4. System / Homebrew fallbacks
    candidatePaths.append("/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/Current/Python")
    candidatePaths.append("/Applications/Garage.app/Contents/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
    candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/Current/Python")
    candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/Current/Python")
    candidatePaths.append("/usr/local/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/Library/Frameworks/Python.framework/Versions/Current/Python")
    candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.13/Python")

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

private func runMCPCLI() {
    setupPostgresEnvironment()
    setupPythonEnvironment()
    #if canImport(PythonKit)
    do {
        try PythonLibrary.loadLibrary()
    } catch {
        fputs("Error: Failed to load Python runtime library: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    do {
        let sys = try Python.attemptImport("sys")
        let pythonLibCandidates = [
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13").standardizedFileURL,
            binDir.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13").standardizedFileURL,
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
        ]

        for libURL in pythonLibCandidates {
            if FileManager.default.fileExists(atPath: libURL.path) {
                sys.path.insert(0, libURL.path)
            }
        }

        let sitePackagesCandidates = [
            execURL.appendingPathComponent("../../Resources/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Resources/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../../Resources/site-packages").standardizedFileURL,
            bundleURL.appendingPathComponent("Contents/Resources/site-packages"),
            bundleURL.appendingPathComponent("Resources/site-packages"),
            binDir.appendingPathComponent("../Resources/site-packages"),
            binDir.appendingPathComponent("site-packages"),
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages").standardizedFileURL,
            execURL.appendingPathComponent("../../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages").standardizedFileURL,
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages").standardizedFileURL,
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            URL(fileURLWithPath: "/Applications/Garage.app/Contents/Resources/site-packages"),
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
            fputs("[GARAGE_MCP] Dynamic Python: \(ProcessInfo.processInfo.environment["PYTHON_LIBRARY"] ?? "default")\n", stderr)
            fputs("[GARAGE_MCP] Dynamic Postgres: \(ProcessInfo.processInfo.environment["GARAGE_LIBPQ_PATH"] ?? "default")\n", stderr)
            fputs("[GARAGE_MCP] Python sys.path: \(sys.path)\n", stderr)
        }

        let mcpModule: PythonObject
        do {
            mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
        } catch {
            if let tb = try? Python.attemptImport("traceback") {
                _ = tb.print_exc()
            }
            fputs("Error executing garage-mcp CLI: \(error)\n", stderr)
            fputs("[GARAGE_MCP] Python sys.path at failure: \(sys.path)\n", stderr)
            exit(1)
        }
        let exitCode = Int(mcpModule.main()) ?? 0
        exit(Int32(exitCode))
    } catch {
        if let tb = try? Python.attemptImport("traceback") {
            _ = tb.print_exc()
        }
        fputs("Error executing garage-mcp CLI: \(error)\n", stderr)
        if let sys = try? Python.attemptImport("sys") {
            fputs("[GARAGE_MCP] Python sys.path at failure: \(sys.path)\n", stderr)
        }
        exit(1)
    }
    #else
    fputs("Error: PythonKit not available\n", stderr)
    exit(1)
    #endif
}

runMCPCLI()
