import SwiftUI
import OSLog

public struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var source: LogSource = .postgres
    @State private var selectedTimeWindow: OSLogTimeWindow = .recent5m

    public enum LogSource: String, CaseIterable, Identifiable, Sendable, Hashable {
        case postgres = "Postgres"
        case garage = "garage CLI"
        case ingest = "Ingest"
        case backfill = "Backfill"
        case mcp = "MCP Server"
        case grpc = "gRPC Server"
        case llama = "Llama Service"
        case modelDownload = "Model Downloader"


        public var id: String { rawValue }

        public var isUnifiedSource: Bool {
            switch self {
            case .ingest, .backfill, .mcp, .grpc, .llama, .modelDownload:
                return true
            case .postgres, .garage:
                return false
            }
        }

        public var osLogPredicate: NSPredicate? {
            switch self {
            case .ingest:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND (category CONTAINS[c] 'ingest' OR category == 'GarageXPCOutputCapture' OR category == 'IngestService' OR category == 'IngestClient' OR category == 'GarageIngestXPCService')) OR process CONTAINS[c] 'GarageIngest'")
            case .llama:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND category CONTAINS[c] 'llama') OR process CONTAINS[c] 'llama'")
            case .modelDownload:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND category CONTAINS[c] 'modeldownload') OR process CONTAINS[c] 'modeldownload'")
            case .mcp:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND category CONTAINS[c] 'mcp') OR process CONTAINS[c] 'mcpserver'")
            case .grpc:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND (category CONTAINS[c] 'grpc' OR category CONTAINS[c] 'grpc')) OR process CONTAINS[c] 'grpc'")
            case .backfill:
                return NSPredicate(format: "(subsystem == 'me.rickmark.garage' AND (category CONTAINS[c] 'embed' OR category CONTAINS[c] 'backfill')) OR process CONTAINS[c] 'embed'")
            case .postgres, .garage:
                return nil
            }
        }

        public var matchingOSLogScope: OSLogScopeFilter? {
            switch self {
            case .ingest:
                return .ingest
            default:
                return nil
            }
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            sourcePickerToolbar
            Divider()

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
        .onAppear {
            configureStreamingForCurrentSource()
        }
        .onChange(of: source) {
            configureStreamingForCurrentSource()
        }
    }

    // MARK: - Source Picker Toolbar

    private var sourcePickerToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Picker("Log Source", selection: $source) {
                ForEach(LogSource.allCases) { src in
                    HStack(spacing: 4) {
                        Text(src.rawValue)
                        if src.isUnifiedSource {
                            Image(systemName: "waveform")
                                .font(.caption2)
                        }
                    }
                    .tag(src)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - OSLog Streaming Controls Bar

    private var osLogStreamingControlsBar: some View {
        HStack(spacing: 12) {
            // Live Status Indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(streamingStatusColor)
                    .frame(width: 8, height: 8)

                Text(streamingStatusText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(appState.osLogStreamService.isStreaming && !appState.osLogStreamService.isPaused ? .primary : .secondary)

                if let lastPolled = appState.osLogStreamService.lastPolledDate {
                    Text("(\(Self.timeFormatter.string(from: lastPolled)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            Divider()
                .frame(height: 14)

            // Pause / Resume Toggle
            Button(action: {
                appState.osLogStreamService.togglePause()
            }) {
                Label(
                    appState.osLogStreamService.isPaused ? "Resume Stream" : "Pause Stream",
                    systemImage: appState.osLogStreamService.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.plain)
            .font(.caption)
            .controlSize(.small)

            Spacer()

            // Time Window Fetch Menu
            Menu {
                ForEach(OSLogTimeWindow.allCases) { window in
                    Button("Fetch Past \(window.rawValue)") {
                        fetchHistoricalOSLogs(window: window)
                    }
                }
            } label: {
                Label("Fetch OSLog", systemImage: "arrow.clockwise.circle")
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .controlSize(.small)
            .help("Fetch historical entries from OSLogStore")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Streaming Actions

    private func configureStreamingForCurrentSource() {
        if source.isUnifiedSource {
            if !appState.osLogStreamService.isStreaming {
                appState.osLogStreamService.startStreaming(since: Date().addingTimeInterval(-300))
            } else {
                appState.osLogStreamService.resumeStreaming()
            }
            if source == .ingest {
                appState.ingestService.fetchRecentLogsFromOSLogStore(timeWindow: 300)
            }
        }
    }

    private func fetchHistoricalOSLogs(window: OSLogTimeWindow) {
        appState.osLogStreamService.fetchRecentLogs(for: source, timeWindow: window.interval)
        if source == .ingest {
            appState.ingestService.fetchRecentLogsFromOSLogStore(timeWindow: window.interval)
        }
    }

    // MARK: - Status Helpers

    private var streamingStatusColor: Color {
        if !appState.osLogStreamService.isStreaming {
            return .secondary
        }
        if appState.osLogStreamService.isPaused {
            return .orange
        }
        return .green
    }

    private var streamingStatusText: String {
        if !appState.osLogStreamService.isStreaming {
            return "OSLog Inactive"
        }
        if appState.osLogStreamService.isPaused {
            return "OSLog Paused (\(source.rawValue))"
        }
        return "Live OSLog (\(source.rawValue))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: - Log Lines Source

    private var lines: [LogLine] {
        switch source {
        case .postgres:
            return appState.postgres.logs
        case .garage:
            return appState.garage.logs
        case .ingest:
            let cliLogs = appState.ingest.logs
            let osLogs = appState.osLogStreamService.logs(for: .ingest)
            if cliLogs.isEmpty { return osLogs }
            if osLogs.isEmpty { return cliLogs }
            return (cliLogs + osLogs).sorted { $0.date < $1.date }
        case .backfill:
            let osLogs = appState.osLogStreamService.logs(for: .backfill)
            let cliLogs = appState.backfill.logs
            return osLogs.isEmpty ? cliLogs : (cliLogs + osLogs).sorted { $0.date < $1.date }
        case .mcp:
            let osLogs = appState.osLogStreamService.logs(for: .mcp)
            return osLogs.isEmpty ? appState.mcp.logs : osLogs
        case .grpc:
            let osLogs = appState.osLogStreamService.logs(for: .grpc)
            return osLogs.isEmpty ? appState.grpc.logs : osLogs
        case .llama:
            let osLogs = appState.osLogStreamService.logs(for: .llama)
            return osLogs.isEmpty ? appState.llama.logs : osLogs
        case .modelDownload:
            let osLogs = appState.osLogStreamService.logs(for: .modelDownload)
            return osLogs.isEmpty ? appState.modelDownload.logs : osLogs
        }
    }
}
