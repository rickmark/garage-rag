import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var source: LogSource = .postgres

    enum LogSource: String, CaseIterable, Identifiable {
        case postgres = "Postgres"
        case garage = "garage CLI"
        case ingest = "Ingest"
        case backfill = "Backfill"
        case mcp = "MCP Server"
        case grpc = "gRPC Server"
        case llama = "Llama Service"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Log Source", selection: $source) {
                ForEach(LogSource.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            LogTableView(
                lines: lines,
                sourceName: source.rawValue,
                onClear: {
                    appState.clearLogs(for: source.rawValue)
                }
            )
            .id(source)
        }
        .navigationTitle("Logs")
    }

    private var lines: [LogLine] {
        switch source {
        case .postgres: appState.postgres.logs
        case .garage: appState.garage.logs
        case .ingest: appState.ingest.logs
        case .backfill: appState.backfill.logs
        case .mcp: appState.mcp.logs
        case .grpc: appState.grpc.logs
        case .llama: appState.llama.logs
        }
    }
}
