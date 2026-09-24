import GarageUpdater
import SwiftUI

@main
struct GarageApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Garage") {
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

    private var menuBarSymbol: String {
        "cylinder.split.1x2"
    }
}
