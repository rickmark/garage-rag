import GarageUpdater
import SwiftUI

/// The menu bar item's popover: what Garage is doing, the two things people come here for
/// (open the window, ingest now), and the app-level commands laid out like a native menu.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = MenuBarStatus(appState: appState)
        VStack(alignment: .leading, spacing: 0) {
            header(status)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let card = activityCard(status) {
                card
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }

            primaryActions(status)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 0) {
                CheckForUpdatesButton(updater: appState.updater)
                Button("Setup Assistant…") {
                    GarageApp.presentFirstRun(appState: appState, openWindow: openWindow)
                }
                Button("About & Support…") {
                    showInMainWindow(.garageShowSplash)
                }
                Button("Report a Bug…") {
                    showInMainWindow(.garageShowBugReport)
                }
            }
            .padding(6)

            Divider().padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    toggleDatabase()
                } label: {
                    Text(databaseToggleTitle)
                }
                .disabled(isTransitioning)
                .help("The database runs on port \(String(appState.postgres.port)).")
                .accessibilityIdentifier("menubar.database.toggle")

                Button {
                    AppDelegate.quit()
                } label: {
                    HStack {
                        Text("Quit Garage")
                        Spacer()
                        Text("⌘Q").foregroundStyle(.secondary)
                    }
                }
                .keyboardShortcut("q")
                .accessibilityIdentifier("menubar.quit")
            }
            .padding(6)
        }
        .buttonStyle(MenuRowButtonStyle())
        .frame(width: 300)
    }

    // MARK: - Header

    private func header(_ status: MenuBarStatus) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Garage")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 7, height: 7)
                    Text(status.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("menubar.status")
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Activity

    /// What is running, or what went wrong, in a card under the header. Nothing when idle: the
    /// corpus summary stands in for it.
    private func activityCard(_ status: MenuBarStatus) -> AnyView? {
        if case .failed(let message) = status.database {
            return AnyView(attentionCard(title: "The database did not start", detail: message))
        }
        if status.database == .needsMigration {
            return AnyView(attentionCard(
                title: "The schema needs a migration",
                detail: "Open Garage to review and apply it."
            ))
        }
        guard status.database == .running else { return nil }

        switch status.activity {
        case .idle:
            return AnyView(corpusSummary)
        case .ingesting(let source, let fraction):
            let current = appState.ingestService.latestProgress?.currentItem ?? ""
            return AnyView(progressCard(
                title: source.isEmpty ? "Ingesting" : "Ingesting \(source)",
                fraction: fraction,
                detail: current.isEmpty ? nil : current,
                cancelTitle: appState.ingestService.isCancelling ? "Cancelling…" : "Cancel Ingest",
                cancelDisabled: appState.ingestService.isCancelling
            ) {
                Task { await appState.cancelIngest() }
            })
        case .scanning:
            let detail = appState.scanProgress.map { "\($0.source): \($0.totalItems.formatted()) items so far" }
            return AnyView(progressCard(
                title: "Scanning sources",
                fraction: nil,
                detail: detail,
                cancelTitle: "Cancel Scan",
                cancelDisabled: false
            ) {
                appState.cancelScan()
            })
        case .embedding:
            return AnyView(progressCard(title: "Embedding chunks", fraction: nil, detail: nil))
        case .distilling:
            return AnyView(progressCard(title: "Distilling facts", fraction: nil, detail: nil))
        }
    }

    private var corpusSummary: some View {
        let stats = appState.corpusStats
        let embedded = stats.totalChunks > 0
            ? MenuBarStatus.percent(Double(stats.embeddedChunks) / Double(stats.totalChunks))
            : "—"
        return HStack(spacing: 0) {
            summaryFigure(stats.documentsCount.formatted(), label: "Documents")
            Divider().frame(height: 26)
            summaryFigure(stats.sourcesCount.formatted(), label: "Sources")
            Divider().frame(height: 26)
            summaryFigure(embedded, label: "Embedded")
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.summary")
    }

    private func summaryFigure(_ value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func progressCard(
        title: String,
        fraction: Double?,
        detail: String?,
        cancelTitle: String? = nil,
        cancelDisabled: Bool = false,
        cancel: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let fraction {
                    Text(MenuBarStatus.percent(fraction))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction {
                ProgressView(value: min(1, max(0, fraction)))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let cancelTitle, let cancel {
                Button(cancelTitle, action: cancel)
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(cancelDisabled)
                    .accessibilityIdentifier("menubar.cancel")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("menubar.activity")
    }

    private func attentionCard(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menubar.attention")
    }

    // MARK: - Primary actions

    private func primaryActions(_ status: MenuBarStatus) -> some View {
        HStack(spacing: 8) {
            Button {
                openMainWindow()
            } label: {
                Text("Open Garage").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("menubar.openGarage")

            Button {
                Task { await appState.ingestAllSources() }
            } label: {
                Text("Ingest Now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(status.database != .running || status.isBusy || appState.registeredSources.isEmpty)
            .help(appState.registeredSources.isEmpty ? "Add a source in Garage first." : "Scan and ingest every source.")
            .accessibilityIdentifier("menubar.ingest")
        }
        .controlSize(.large)
    }

    // MARK: - Actions

    /// Brings the main window forward, or opens a new one when a `--background` launch (by the
    /// `garage` and `garage-mcp` launchers) never showed it or the user closed it.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows.filter { $0.title == "Garage" }
        if windows.isEmpty {
            openWindow(id: GarageApp.mainWindowID)
        } else {
            for window in windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Brings the main window forward and asks it to put up a dialog. The
    /// menu bar popover can't host one itself - it closes the moment focus
    /// moves.
    private func showInMainWindow(_ notification: Notification.Name) {
        let hadWindow = NSApp.windows.contains { $0.title == "Garage" }
        openMainWindow()
        if hadWindow {
            NotificationCenter.default.post(name: notification, object: nil)
        } else {
            // A new window's ContentView subscribes as it appears; give it a turn of the run loop.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notification, object: nil)
            }
        }
    }

    private func toggleDatabase() {
        Task {
            if appState.postgres.status == .running {
                await appState.stopPostgres()
            } else {
                await appState.startPostgres()
            }
        }
    }

    private var databaseToggleTitle: String {
        switch appState.postgres.status {
        case .running: "Stop Database"
        case .starting: "Starting Database…"
        case .stopping: "Stopping Database…"
        default: "Start Database"
        }
    }

    private var isTransitioning: Bool {
        appState.postgres.status == .starting || appState.postgres.status == .stopping
    }
}

/// A full-width row that highlights under the pointer, like an item in a native menu.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let highlighted = isEnabled && (isHovering || configuration.isPressed)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(foreground(highlighted: highlighted))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(highlighted ? AnyShapeStyle(TintShapeStyle.tint) : AnyShapeStyle(Color.clear))
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }

        private func foreground(highlighted: Bool) -> AnyShapeStyle {
            if highlighted { return AnyShapeStyle(Color.white) }
            return isEnabled ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
        }
    }
}
