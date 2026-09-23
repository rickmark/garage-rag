import SwiftUI

/// Confirms "Reset Database". It spells out that everything Garage built from the user's files goes
/// (the index, facts, conversation memory) and that the files themselves stay, then hands off to
/// `AppState.resetDatabaseAndRelaunch()`, which stops the services, deletes the cluster and
/// relaunches the app to create a new one.
@MainActor
struct DatabaseResetSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("Reset the Garage database?")
                    .font(.title2.bold())
            }
            Text("Garage deletes its database and starts over with an empty one. Your original files are not touched.")
                .fixedSize(horizontal: false, vertical: true)

            ResetSection(title: "Deleted", systemImage: "trash", tint: .red, items: deletedItems)
            ResetSection(title: "Kept", systemImage: "checkmark.circle", tint: .green, items: keptItems)

            Text(
                "Garage stops its services, deletes \(Paths.pgDataDir.path), and relaunches to create a new "
                    + "database. Afterwards, register your embedding models again on the Models page and run "
                    + "ingest to rebuild the index."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Reset and Relaunch", role: .destructive) {
                    dismiss()
                    Task { await appState.resetDatabaseAndRelaunch() }
                }
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var deletedItems: [ResetItem] {
        let stats = appState.corpusStats
        let indexDetail = stats.documentsCount > 0
            ? "\(stats.documentsCount) indexed documents, their \(stats.totalChunks) chunks, and their embeddings under every model."
            : "Every indexed document, its chunks, and their embeddings under every model."
        return [
            ResetItem(title: "The search index", detail: indexDetail),
            ResetItem(title: "Facts", detail: "Every fact distilled from your documents."),
            ResetItem(
                title: "Conversation memory",
                detail: "The copies of message and mail threads Garage imported. The originals in Messages and Mail stay."
            ),
            ResetItem(
                title: "Registrations and history",
                detail: "Registered sources and embedding models, authorship, and ingest history."
            ),
        ]
    }

    private let keptItems: [ResetItem] = [
        ResetItem(
            title: "Your original files",
            detail: "Nothing in your sources' folders, repositories, mail or message archives is moved or deleted."
        ),
        ResetItem(
            title: "Models, logs and settings",
            detail: "Downloaded model files, logs, and garage.json. The sources garage.json declares are registered again automatically."
        ),
        ResetItem(title: "The database password", detail: "It stays in your Keychain; the new database uses it."),
    ]
}

private struct ResetItem: Identifiable {
    let title: String
    let detail: String
    var id: String { title }
}

private struct ResetSection: View {
    let title: String
    let systemImage: String
    let tint: Color
    let items: [ResetItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }
}
