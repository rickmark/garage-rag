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

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        "cylinder.split.1x2"
    }
}
