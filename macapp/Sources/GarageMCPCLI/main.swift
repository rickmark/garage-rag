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

    // 1. Inside .app bundle (Contents/Resources/postgres/lib/libpq.dylib)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Resources/postgres/lib/libpq.5.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Resources/postgres/lib/libpq.5.dylib").path)

    // 2. Relative to standalone CLI binary
    candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("../Resources/postgres/lib/libpq.5.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("postgres/lib/libpq.5.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.dylib").path)
    candidatePaths.append(binDir.appendingPathComponent("../postgres/lib/libpq.5.dylib").path)

    // 3. Bundle.main resourceURL
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

    // 1. Inside .app bundle (Contents/Frameworks/Python.framework)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Python").path)

    // 2. Relative to standalone CLI binary (../Frameworks/Python.framework)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/Current/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/3.13/Python").path)

    // 3. System / Homebrew fallbacks
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
            setenv("PYTHON_LIBRARY", path, 1)
            break
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
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13"),
        ]

        for libURL in pythonLibCandidates {
            if FileManager.default.fileExists(atPath: libURL.path) {
                sys.path.insert(0, libURL.path)
            }
        }

        let sitePackagesCandidates = [
            bundleURL.appendingPathComponent("Contents/Resources/site-packages"),
            bundleURL.appendingPathComponent("Resources/site-packages"),
            binDir.appendingPathComponent("../Resources/site-packages"),
            binDir.appendingPathComponent("site-packages"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/Current/lib/python3.13/site-packages"),
            binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages"),
        ]

        for spURL in sitePackagesCandidates {
            if FileManager.default.fileExists(atPath: spURL.path) {
                sys.path.insert(0, spURL.path)
            }
        }

        // Set sys.argv
        sys.argv = PythonObject(CommandLine.arguments)

        let mcpModule = try Python.attemptImport("garage_rag.mcp_server.server")
        let exitCode = Int(mcpModule.main()) ?? 0
        exit(Int32(exitCode))
    } catch {
        fputs("Error executing garage-mcp CLI: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    #else
    fputs("Error: PythonKit not available\n", stderr)
    exit(1)
    #endif
}

runMCPCLI()
