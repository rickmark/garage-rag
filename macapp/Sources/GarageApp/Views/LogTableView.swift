import SwiftUI
import AppKit

/// Filter options for log severity levels.
public enum LogLevelFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Levels"
    case error = "Error"
    case warning = "Warning"
    case info = "Info"
    case debug = "Debug"
    case warningsAndErrors = "Warnings & Errors"

    public var id: String { rawValue }

    public func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all:
            return true
        case .error:
            return level == .error
        case .warning:
            return level == .warning
        case .info:
            return level == .info
        case .debug:
            return level == .debug
        case .warningsAndErrors:
            return level == .warning || level == .error
        }
    }
}

/// Filter options for log output streams (stdout vs stderr).
public enum LogStreamFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Streams"
    case stdout = "stdout"
    case stderr = "stderr"

    public var id: String { rawValue }

    public func matches(_ stream: LogLine.Stream) -> Bool {
        switch self {
        case .all: return true
        case .stdout: return stream == .stdout
        case .stderr: return stream == .stderr
        }
    }
}

/// A comprehensive, sortable, and filterable table view for log entries.
public struct LogTableView: View {
    public let lines: [LogLine]
    public var sourceName: String?
    public var onClear: (() -> Void)?

    @State private var searchText = ""
    @State private var levelFilter: LogLevelFilter = .all
    @State private var streamFilter: LogStreamFilter = .all
    @State private var selectedLineIDs = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LogLine.date, order: .forward)]
    @State private var showDetailInspector = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(
        lines: [LogLine],
        sourceName: String? = nil,
        onClear: (() -> Void)? = nil
    ) {
        self.lines = lines
        self.sourceName = sourceName
        self.onClear = onClear
    }

    private var effectiveSelectedLine: LogLine? {
        if let firstID = selectedLineIDs.first {
            return lines.first(where: { $0.id == firstID })
        }
        return nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            filterToolbar
            Divider()
            contentView
            if showDetailInspector, let line = effectiveSelectedLine {
                Divider()
                detailInspectorView(for: line)
            }
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            // Text Search Field
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Filter logs (text, source, level)…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 180, maxWidth: 300)

            // Level Picker
            Picker("Level", selection: $levelFilter) {
                ForEach(LogLevelFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 140)

            // Stream Picker
            Picker("Stream", selection: $streamFilter) {
                ForEach(LogStreamFilter.allCases) { stream in
                    Text(stream.rawValue).tag(stream)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 120)

            if hasActiveFilters {
                Button("Reset Filters") {
                    resetFilters()
                }
                .controlSize(.small)
            }

            Spacer()

            // Count Badge
            Text("\(filteredLines.count) of \(lines.count) entries")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Actions
            HStack(spacing: 6) {
                Button(action: copyLogsToClipboard) {
                    Label(selectedLineIDs.isEmpty ? "Copy All" : "Copy Selected", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy log entries to clipboard")

                Toggle(isOn: $showDetailInspector) {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle log entry detail inspector")

                if let onClear = onClear {
                    Button(action: onClear) {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(lines.isEmpty)
                    .help("Clear logs for this source")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Main Content

    @ViewBuilder
    private var contentView: some View {
        if lines.isEmpty {
            emptyStateView(
                icon: "text.alignleft",
                title: "No Logs Recorded",
                subtitle: sourceName != nil ? "No log output has been produced by \(sourceName!) yet." : "No log output recorded yet."
            )
        } else if filteredLines.isEmpty {
            emptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matches",
                subtitle: "No log entries match your active filter criteria."
            )
        } else {
            tableContent
        }
    }

    private var tableContent: some View {
        Table(filteredLines, selection: $selectedLineIDs, sortOrder: $sortOrder) {
            TableColumn("Time", value: \.date) { line in
                Text(Self.timestampFormatter.string(from: line.date))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 85, ideal: 95, max: 115)

            TableColumn("PID") { line in
                if let pid = line.pid {
                    Text("\(pid)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("-")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 45, ideal: 55, max: 75)

            TableColumn("Level", value: \.level) { line in
                LogLevelBadge(level: line.level)
            }
            .width(min: 75, ideal: 85, max: 100)

            TableColumn("Stream", value: \.stream) { line in
                LogStreamBadge(stream: line.stream)
            }
            .width(min: 55, ideal: 65, max: 80)

            TableColumn("Source", value: \.source) { line in
                Text(line.source)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 90, max: 130)

            TableColumn("Message", value: \.text) { line in
                Text(line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(line.level == .error ? .red : (line.level == .warning ? .orange : (line.level == .debug ? .secondary : .primary)))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIDs in
            if !selectedIDs.isEmpty {
                Button("Copy Selected (\(selectedIDs.count))") {
                    copySelectedLines(ids: selectedIDs)
                }
                Button("Inspect Selected") {
                    if let firstID = selectedIDs.first {
                        selectedLineIDs = [firstID]
                        showDetailInspector = true
                    }
                }
            }
            Button("Copy All Filtered") {
                copyFilteredLogs()
            }
        }
    }

    // MARK: - Detail Inspector View

    private func detailInspectorView(for line: LogLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    LogLevelBadge(level: line.level)
                    LogStreamBadge(stream: line.stream)
                    if let pid = line.pid {
                        Text("PID: \(pid)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.secondary)
                    }
                    Text("Source: \(line.source)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(Self.timestampFormatter.string(from: line.date))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Text") {
                    NSPasteboard.general.copy(line.rawText ?? line.text)
                }
                .controlSize(.small)

                Button(action: { showDetailInspector = false }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.level == .error ? .red : (line.level == .warning ? .orange : (line.level == .debug ? .secondary : .primary)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if let raw = line.rawText, raw != line.text {
                        Divider()
                            .padding(.vertical, 2)
                        Text("Raw: \(raw)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Helpers & State

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || levelFilter != .all || streamFilter != .all
    }

    private func resetFilters() {
        searchText = ""
        levelFilter = .all
        streamFilter = .all
    }

    public var filteredLines: [LogLine] {
        var result = lines

        if levelFilter != .all {
            result = result.filter { levelFilter.matches($0.level) }
        }

        if streamFilter != .all {
            result = result.filter { streamFilter.matches($0.stream) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.matches(searchText: query) }
        }

        return result.sorted(using: sortOrder)
    }

    private func copyLogsToClipboard() {
        if !selectedLineIDs.isEmpty {
            copySelectedLines(ids: selectedLineIDs)
        } else {
            copyFilteredLogs()
        }
    }

    private func copyFilteredLogs() {
        let content = filteredLines.map { formatLogLineForExport($0) }.joined(separator: "\n")
        NSPasteboard.general.copy(content)
    }

    private func copySelectedLines(ids: Set<UUID>) {
        let matched = filteredLines.filter { ids.contains($0.id) }
        let content = matched.map { formatLogLineForExport($0) }.joined(separator: "\n")
        NSPasteboard.general.copy(content)
    }

    private func formatLogLineForExport(_ line: LogLine) -> String {
        let pidStr = line.pid.map { " [pid:\($0)]" } ?? ""
        return "[\(Self.timestampFormatter.string(from: line.date))] [\(line.level.rawValue.uppercased())] [\(line.source)/\(line.stream.rawValue)]\(pidStr) \(line.text)"
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasActiveFilters {
                Button("Reset Filters") {
                    resetFilters()
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
