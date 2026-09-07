import AppKit

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true

        let state = self.appState

        Task { @MainActor in
            let shutdownTask = Task { @MainActor in
                if let state = state {
                    await state.stopPostgres()
                } else {
                    PostgresService.stopAnyRunningInstance()
                }
            }

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                shutdownTask.cancel()
            }

            _ = await shutdownTask.result
            timeoutTask.cancel()

            state?.mcp.terminateImmediately()
            state?.postgres.terminateImmediately()
            PostgresService.stopAnyRunningInstance()

            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.mcp.terminateImmediately()
        appState?.postgres.terminateImmediately()
        PostgresService.stopAnyRunningInstance()
    }
}
