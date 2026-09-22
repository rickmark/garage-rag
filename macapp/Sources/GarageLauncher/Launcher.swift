import Darwin
import Foundation
import PythonKit
import PythonXPCService

/// One of the Mach-O launchers bundled in `Garage.app/Contents/MacOS`: which Python
/// entry point it runs and how.
public struct LauncherEntryPoint {
    let module: String
    let function: String
    /// Mirror stdout/stderr into the unified log. Off for `garage-mcp`: its stdout is
    /// the MCP protocol stream, which carries corpus text.
    let mirrorsOutputToLog: Bool
    /// Whether this invocation talks to the database, so the app has to be running.
    let needsDatabase: ([String]) -> Bool

    /// `garage`: the full CLI.
    public static let cli = LauncherEntryPoint(
        module: "garage_rag.cli",
        function: "main_cli",
        mirrorsOutputToLog: true,
        needsDatabase: LauncherEntryPoint.cliNeedsDatabase
    )

    /// `garage-mcp [--config PATH]`: the stdio MCP server that clients spawn.
    public static let mcp = LauncherEntryPoint(
        module: "garage_rag.mcp_server.server",
        function: "main",
        mirrorsOutputToLog: false,
        needsDatabase: { arguments in !arguments.contains("--help") && !arguments.contains("-h") }
    )

    /// Subcommands that never open the database.
    static let commandsWithoutDatabase: Set<String> = ["config", "mcp-install", "mcp-uninstall", "mcp-status", "version"]

    /// `garage [global options] COMMAND ...`: false for help, bare `garage` and
    /// `commandsWithoutDatabase`, so those work without starting the app.
    static func cliNeedsDatabase(_ arguments: [String]) -> Bool {
        if arguments.contains("--help") || arguments.contains("-h") {
            return false
        }
        var remaining = arguments.dropFirst()
        while let option = remaining.first, option.hasPrefix("-") {
            remaining = remaining.dropFirst()
            if option == "--config" || option == "-c" {
                remaining = remaining.dropFirst()
            }
        }
        guard let command = remaining.first else { return false }
        return !commandsWithoutDatabase.contains(command)
    }
}

public enum Launcher {
    /// Runs `entry` in the embedded interpreter and exits with its status.
    public static func run(_ entry: LauncherEntryPoint) -> Never {
        let executable = executablePath()
        let appBundle = containingAppBundle(of: executable)
        exportLauncherPaths(nextTo: executable)

        if entry.needsDatabase(CommandLine.arguments) {
            do {
                try AppDatabase.prepare(appBundle: appBundle, executable: executable.path)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if entry.mirrorsOutputToLog {
            LauncherOutputCapturer.shared.start()
        }
        let status = runPython(entry, appBundle: appBundle)
        if entry.mirrorsOutputToLog {
            LauncherOutputCapturer.shared.flush()
        }
        exit(status)
    }

    /// This binary's real path. `Bundle.main` cannot say: for an executable inside
    /// `Contents/MacOS` it is the app bundle, whose executable is GarageApp.
    static func executablePath() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    /// `Garage.app` for `Garage.app/Contents/MacOS/<launcher>`, else nil.
    static func containingAppBundle(of executable: URL) -> URL? {
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    /// Tells Python where both launchers are, so `mcp-install` / `mcp-status` name a
    /// command an MCP client can run (sys.executable names an interpreter the bundle
    /// does not ship).
    private static func exportLauncherPaths(nextTo executable: URL) {
        let directory = executable.deletingLastPathComponent()
        for (name, variable) in [("garage", "GARAGE_CLI_EXECUTABLE"), ("garage-mcp", "GARAGE_MCP_EXECUTABLE")] {
            let path = directory.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                setenv(variable, path, 1)
            }
        }
    }

    /// Starts the isolated interpreter (PyConfig API) with `home`, stdlib, `lib-dynload`
    /// and `site-packages` from `<Garage.app>/Contents/Resources/site-python`, exactly
    /// like the XPC services do.
    private static func startPython(appBundle: URL?) -> Bool {
        let runtime = GaragePythonRuntime.shared
        if let appBundle {
            runtime.setAppBundle(url: appBundle)
        }
        switch runtime.initializeIfNeeded() {
        case .success(let env):
            if isDebugging {
                fputs("[GARAGE_CLI] Python home: \(env.home.path)\n", stderr)
            }
            return true
        case .failure(let error):
            fputs("Error starting embedded Python: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private static var isDebugging: Bool {
        ProcessInfo.processInfo.environment["GARAGE_DEBUG"] != nil || CommandLine.arguments.contains("--debug")
    }

    private static func runPython(_ entry: LauncherEntryPoint, appBundle: URL?) -> Int32 {
        guard startPython(appBundle: appBundle) else {
            return 1
        }
        do {
            return try GaragePythonRuntime.shared.withGIL {
                let sys = try Python.attemptImport("sys")
                sys.argv = PythonObject(CommandLine.arguments)
                attachStandardStreams(sys)

                do {
                    _ = try Python.attemptImport("site")
                } catch {
                    fputs("Warning: Could not import site module: \(error)\n", stderr)
                }

                if isDebugging {
                    let env = ProcessInfo.processInfo.environment
                    fputs("[GARAGE_CLI] Dynamic Python: \(env["PYTHON_LIBRARY"] ?? "default")\n", stderr)
                    fputs("[GARAGE_CLI] Dynamic Postgres: \(env["GARAGE_LIBPQ_PATH"] ?? "default")\n", stderr)
                    fputs("[GARAGE_CLI] Python sys.path: \(sys.path)\n", stderr)
                }

                let module: PythonObject
                do {
                    module = try Python.attemptImport(entry.module)
                } catch {
                    if let traceback = try? Python.attemptImport("traceback") {
                        _ = traceback.print_exc()
                    }
                    fputs("Error importing \(entry.module): \(error)\n", stderr)
                    fputs("[GARAGE_CLI] Python sys.path at failure: \(sys.path)\n", stderr)
                    return 1
                }
                // The throwing call surfaces Python exceptions as errors instead of PythonKit's `try!` trap.
                let result = try module[dynamicMember: entry.function].throwing.dynamicallyCall(withArguments: [])
                return Int32(Int(result) ?? 0)
            }
        } catch {
            // Traceback formatting and any other Python access must happen with the GIL held.
            _ = try? GaragePythonRuntime.shared.withGIL {
                fputs("Error running \(entry.module).\(entry.function): \(GaragePythonRuntime.describe(error))\n", stderr)
            }
            return 1
        }
    }

    /// Hands Python usable stdin/stdout/stderr when the embedded interpreter has none.
    private static func attachStandardStreams(_ sys: PythonObject) {
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
    }
}
