import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case sources = "Sources & Ingest"
    case models = "Embedding Models"
    case search = "Search"
    case logs = "Logs"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .sources: "tray.and.arrow.down"
        case .models: "cpu"
        case .search: "magnifyingglass"
        case .logs: "terminal"
        }
    }
}

struct ContentView: View {
    @State private var selection: AppSection? = .status

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch selection ?? .status {
            case .status: StatusView()
            case .sources: SourcesView()
            case .models: ModelsView()
            case .search: SearchView()
            case .logs: LogsView()
            }
        }
    }
}
