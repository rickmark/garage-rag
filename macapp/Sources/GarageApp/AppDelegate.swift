import AppKit
import PythonXPCService

/// Keeps the app running in the menu bar after the main window closes (this
/// is a menu-bar-resident app, not a document-based one), and makes sure the
/// Postgres child process is signaled and stopped on every quit path — Cmd+Q,
/// Dock > Quit, system shutdown, or the menu bar's own Quit item — not just the one button
/// that calls AppState.stopPostgres() directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState? {
        get { _appState ?? AppState.shared }
        set { _appState = newValue }
    }
    private var _appState: AppState?
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The `garage` / `garage-mcp` launchers open the app with `--background` when its
    /// database is not running: start the services, keep to the menu bar, and close
    /// the window SwiftUI opens at launch (the Dock icon or menu bar item reopens it).
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.contains(GarageAppLaunch.backgroundArgument) else { return }
        Task { @MainActor [weak self] in
            self?.appState?.launch()
            for window in NSApp.windows where window.title == "Garage" {
                window.close()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true

        let state = self.appState
        // After "Reset Database" relaunched the app, everything here is already stopped and what is
        // running belongs to the new instance: quit at once, without the shutdown below.
        if state?.hasHandedOffToRelaunch == true {
            return .terminateNow
        }

        Task { @MainActor in
            let shutdownTask = Task { @MainActor in
                if let state = state {
                    await state.stopPostgres()
                } else {
                    await PostgresService.stopAnyRunningInstance()
                }
            }

            // Room for Postgres's shutdown checkpoint (PostgresService.stop polls for up to 10s).
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                shutdownTask.cancel()
            }

            _ = await shutdownTask.result
            timeoutTask.cancel()

            if let state = state {
                state.terminateImmediately()
            } else {
                XPCServiceManager.stopAnyRunningInstances()
                PostgresService.stopAnyRunningInstanceSync()
            }

            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let state = appState {
            state.terminateImmediately()
        } else {
            XPCServiceManager.stopAnyRunningInstances()
            PostgresService.stopAnyRunningInstanceSync()
        }
    }
}
