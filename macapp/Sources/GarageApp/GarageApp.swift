import GarageUpdater
import SwiftUI

@main
struct GarageApp: App {
    /// The main window's scene id, so menu items can recreate it with
    /// `openWindow(id:)` after a `--background` launch closed it.
    static let mainWindowID = "garage.main"

    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Garage", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    appDelegate.appState = appState
                    appState.launch()
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Garage…") {
                    showSplash()
                }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appState.updater)
                Button("Setup Assistant…") {
                    showFirstRun()
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Garage") {
                    AppDelegate.quit()
                }
                .keyboardShortcut("q")
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: menuBarSymbol)
                // The menu bar item exists even when the window does not (a `--background`
                // launch by the garage / garage-mcp launchers), so services start from here too.
                .onAppear { appState.launch() }
        }
        .menuBarExtraStyle(.window)
    }

    /// Brings the main window forward and asks it to present the splash.
    private func showSplash() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Garage" {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(name: .garageShowSplash, object: nil)
    }

    /// Re-runs the setup assistant: opens the main window (recreating it when a
    /// `--background` launch closed it) and flips the coordinator, which
    /// `ContentView` renders from `appState` rather than from the notification.
    private func showFirstRun() {
        Self.presentFirstRun(appState: appState, openWindow: openWindow)
    }

    @MainActor
    static func presentFirstRun(appState: AppState, openWindow: OpenWindowAction) {
        openWindow(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Garage" {
            window.makeKeyAndOrderFront(nil)
        }
        // Closes the splash sheet in any window that is showing it.
        NotificationCenter.default.post(name: .garageShowFirstRun, object: nil)
        appState.firstRun.begin(force: true)
    }

    private var menuBarSymbol: String {
        "cylinder.split.1x2"
    }
}
