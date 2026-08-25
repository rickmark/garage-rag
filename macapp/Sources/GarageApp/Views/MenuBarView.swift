import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(appState.statusColor)
                    .frame(width: 8, height: 8)
                Text("Postgres: \(appState.statusSummary)")
                    .font(.system(size: 12, weight: .medium))
            }

            Divider()

            HStack(spacing: 8) {
                Button(startStopTitle) {
                    Task {
                        if appState.postgres.status == .running {
                            await appState.stopPostgres()
                        } else {
                            await appState.startPostgres()
                        }
                    }
                }
                .disabled(isTransitioning)

                Button("Open Garage") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.title == "Garage" {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            }

            Divider()

            Button("Quit Garage") {
                Task {
                    await appState.stopPostgres()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var startStopTitle: String {
        appState.postgres.status == .running ? "Stop" : "Start"
    }

    private var isTransitioning: Bool {
        appState.postgres.status == .starting || appState.postgres.status == .stopping
    }
}
