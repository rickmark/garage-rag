import SwiftUI
import PythonXPCService

enum AppSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case database = "Database"
    case sources = "Sources & Ingest"
    case documents = "Documents"
    case models = "Models"
    case mcp = "MCP Server"
    case search = "Search"
    case logs = "Logs"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .database: "cylinder.split.1x2"
        case .sources: "tray.and.arrow.down"
        case .documents: "doc.text.magnifyingglass"
        case .models: "cpu"
        case .mcp: "server.rack"
        case .search: "magnifyingglass"
        case .logs: "terminal"
        }
    }
}

struct ContentView: View {
    @State private var selection: AppSection? = .status
    @State private var isSplashPresented = false
    @AppStorage(SplashPreferences.showAtLaunchKey) private var showSplashAtLaunch = true

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityIdentifier("sidebar.\(section)")
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch selection ?? .status {
            case .status: StatusView(selection: $selection)
            case .database: DatabaseView()
            case .sources: SourcesView()
            case .documents: DocumentsView()
            case .models: ModelsView()
            case .mcp: MCPServerView()
            case .search: SearchView()
            case .logs: LogsView()
            }
        }
        .onAppear(perform: presentSplashAtLaunchIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .garageShowSplash)) { _ in
            isSplashPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .garageWillQuit)) { _ in
            isSplashPresented = false
        }
        .sheet(isPresented: $isSplashPresented) {
            SplashView()
        }
    }

    /// Shows the splash once per launch unless the user turned it off (or we
    /// are running under XCTest, where a modal sheet would get in the way).
    private func presentSplashAtLaunchIfNeeded() {
        guard showSplashAtLaunch,
              !isRunningInTestEnvironment,
              // The app relaunched itself after "Reset Database"; it is not a new launch to greet.
              !CommandLine.arguments.contains(GarageAppLaunch.databaseResetArgument),
              !SplashLaunchGate.hasPresented else { return }
        SplashLaunchGate.hasPresented = true
        isSplashPresented = true
    }
}
