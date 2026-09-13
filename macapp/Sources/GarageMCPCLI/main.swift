import Foundation
#if canImport(PythonKit)
import PythonKit
#endif

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
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Versions/3.14/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Contents/Frameworks/Python.framework/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Versions/3.14/Python").path)
    candidatePaths.append(bundleURL.appendingPathComponent("Frameworks/Python.framework/Python").path)

    // 2. Relative to standalone CLI binary (../Frameworks/Python.framework)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Versions/3.14/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("../Frameworks/Python.framework/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Frameworks/Python.framework/Versions/3.14/Python").path)
    candidatePaths.append(binDir.appendingPathComponent("Python.framework/Versions/3.14/Python").path)

    // 3. System / Homebrew fallbacks
    candidatePaths.append("/opt/homebrew/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
    candidatePaths.append("/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.14/Python")
    candidatePaths.append("/opt/homebrew/Frameworks/Python.framework/Versions/3.13/Python")
    candidatePaths.append("/usr/local/opt/python@3.14/Frameworks/Python.framework/Versions/3.14/Python")
    candidatePaths.append("/Library/Frameworks/Python.framework/Versions/3.14/Python")

    for path in candidatePaths {
        if FileManager.default.fileExists(atPath: path) {
            setenv("PYTHON_LIBRARY", path, 1)
            break
        }
    }
}

private func runMCPCLI() {
    setupPythonEnvironment()
    #if canImport(PythonKit)
    let sys = Python.import("sys")
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let bundleURL = binDir.deletingLastPathComponent().deletingLastPathComponent()

    let sitePackagesCandidates = [
        bundleURL.appendingPathComponent("Contents/Resources/site-packages"),
        bundleURL.appendingPathComponent("Resources/site-packages"),
        binDir.appendingPathComponent("../Resources/site-packages"),
        binDir.appendingPathComponent("site-packages"),
    ]

    for spURL in sitePackagesCandidates {
        if FileManager.default.fileExists(atPath: spURL.path) {
            sys.path.insert(0, spURL.path)
        }
    }

    // Set sys.argv
    sys.argv = PythonObject(CommandLine.arguments)

    let mcpModule = Python.import("garage_rag.mcp_server.server")
    mcpModule.main()
    #else
    fputs("Error: PythonKit not available\n", stderr)
    exit(1)
    #endif
}

runMCPCLI()
