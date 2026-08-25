import SwiftUI

struct SearchView: View {
    @EnvironmentObject var appState: AppState

    @State private var query = ""
    @State private var model = ""
    @State private var mode = "hybrid"
    @State private var limit = 10
    @State private var busy = false

    private let modes = ["hybrid", "vector", "fts"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("what did I conclude about…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Picker("", selection: $mode) {
                    ForEach(modes, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 120)
                TextField("model", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Stepper("limit \(limit)", value: $limit, in: 1...50)
                    .frame(width: 110)
                Button("Search") { runSearch() }
                    .disabled(query.isEmpty || appState.postgres.status != .running || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                Text(appState.lastCommandOutput)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
        }
        .navigationTitle("Search")
    }

    private func runSearch() {
        var args = ["search", query, "--mode", mode, "--limit", String(limit)]
        if !model.isEmpty { args += ["--model", model] }
        busy = true
        Task {
            await appState.runGarage(args)
            busy = false
        }
    }
}
