import AppKit
import SwiftUI

/// The search field at the top of the menu bar popover: the first five hybrid-search hits for
/// whatever is typed, a quarter of a second after typing stops. A hit opens the file it came from;
/// Return, or "See all results", hands the query to the Search page.
struct MenuBarQuickSearch: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Off while the database is down, when there is nothing to search.
    let isEnabled: Bool

    @State private var query = ""
    @State private var results: [SearchResultItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    static let resultLimit = 5
    static let debounce: Duration = .milliseconds(250)

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field

            if !results.isEmpty {
                MenuBarModule {
                    ForEach(results) { hit in
                        resultRow(hit)
                    }
                    seeAllRow
                }
                .accessibilityIdentifier("menubar.search.results")
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
            } else if !trimmedQuery.isEmpty, !isSearching {
                Text("No matches")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: query) { _, _ in
            schedule()
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { clear() }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(isEnabled ? "Search your corpus" : "Search needs the database", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(showAll)
                .disabled(!isEnabled)
                .accessibilityIdentifier("menubar.search.field")
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func resultRow(_ hit: SearchResultItem) -> some View {
        MenuBarRow(
            symbol: Self.symbol(forCorpusClass: hit.corpusClass),
            tint: Self.tint(forCorpusClass: hit.corpusClass),
            title: hit.displayTitle,
            detail: Self.oneLine(hit.snippet.isEmpty ? hit.text : hit.snippet),
            showsChevron: false,
            action: { open(hit) }
        )
        .accessibilityIdentifier("menubar.search.result")
    }

    private var seeAllRow: some View {
        Button(action: showAll) {
            HStack {
                Text("See all results in Garage")
                    .font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityIdentifier("menubar.search.all")
    }

    // MARK: - Behaviour

    private func schedule() {
        searchTask?.cancel()
        errorMessage = nil
        let text = trimmedQuery
        guard isEnabled, !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let hits = try await appState.search(query: text, limit: Self.resultLimit)
                guard !Task.isCancelled else { return }
                results = hits
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        errorMessage = nil
        isSearching = false
    }

    /// A file hit opens in its own app; anything else (a message, a document without a path) goes
    /// to the Search page, where the full text is.
    private func open(_ hit: SearchResultItem) {
        if let url = URL(string: hit.uri), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        showAll()
    }

    private func showAll() {
        let text = trimmedQuery
        guard !text.isEmpty else { return }
        MenuBarNavigation.show(.search, query: text, openWindow: openWindow)
    }

    // MARK: - Presentation

    static func symbol(forCorpusClass corpusClass: String) -> String {
        switch corpusClass.lowercased() {
        case "code": "chevron.left.forwardslash.chevron.right"
        case "communication": "bubble.left.and.bubble.right"
        default: "doc.text"
        }
    }

    static func tint(forCorpusClass corpusClass: String) -> Color {
        switch corpusClass.lowercased() {
        case "code": .purple
        case "communication": .green
        default: .blue
        }
    }

    /// Collapses a snippet's whitespace so it fits one row.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
