import AppKit

/// Keeps the app running in the menu bar after the main window closes (this
/// is a menu-bar-resident app, not a document-based one), and makes sure the
/// Postgres child process is signaled to stop on every quit path — Cmd+Q,
/// Dock > Quit, or the menu bar's own Quit item — not just the one button
/// that calls AppState.stopPostgres() directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // No async/await here: the process may be torn down before an
        // awaited Task completes. terminate() just sends SIGTERM and
        // returns immediately, which is enough — postgres handles its own
        // shutdown from there, orphaned but signaled.
        appState?.mcp.terminateImmediately()
        appState?.postgres.terminateImmediately()
    }
}
