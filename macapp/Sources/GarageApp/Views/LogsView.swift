import SwiftUI

struct LogsView: View {
    @EnvironmentObject var appState: AppState
    @State private var source: LogSource = .postgres

    enum LogSource: String, CaseIterable, Identifiable {
        case postgres = "Postgres"
        case garage = "garage CLI"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $source) {
                ForEach(LogSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.stream == .stderr ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .textSelection(.enabled)
                }
                .onChange(of: lines.count) {
                    if let last = lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Logs")
    }

    private var lines: [LogLine] {
        switch source {
        case .postgres: appState.postgres.logs
        case .garage: appState.garage.logs
        }
    }
}
