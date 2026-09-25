import AppKit
import SwiftUI

/// The menu bar item's popover. Top to bottom: a quick search of the corpus, the two services a
/// glance is about (the database, and the MCP server Claude talks to), what the pipeline is doing
/// with a way to start or stop it, and the two commands every menu bar app owes its user.
///
/// Everything else the app can do lives in the window, one click away on any row.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 320

    var body: some View {
        let status = MenuBarStatus(appState: appState)
        VStack(alignment: .leading, spacing: 10) {
            MenuBarQuickSearch(isEnabled: status.canSearch)

            servicesModule(status)

            activityModule(status)

            VStack(spacing: 0) {
                MenuBarCommandRow(title: "Open Garage", key: "o") {
                    MenuBarNavigation.openMainWindow(openWindow: openWindow)
                }
                .accessibilityIdentifier("menubar.openGarage")

                MenuBarCommandRow(title: "Quit Garage", key: "q") {
                    AppDelegate.quit()
                }
                .accessibilityIdentifier("menubar.quit")
            }
            .padding(.horizontal, -4)
        }
        .padding(12)
        .frame(width: Self.width)
    }

    // MARK: - Services

    private func servicesModule(_ status: MenuBarStatus) -> some View {
        MenuBarModule {
            MenuBarRow(
                symbol: "cylinder.split.1x2",
                tint: status.databaseTint,
                isActive: status.database == .running,
                title: "Database",
                detail: databaseDetail(status),
                detailTint: status.database.isFailure ? .red : nil,
                action: { show(.database) }
            ) {
                databaseAction(status)
            }
            .accessibilityIdentifier("menubar.database")

            Divider().padding(.leading, 46)

            MenuBarRow(
                symbol: "server.rack",
                tint: status.mcpTint,
                isActive: status.mcp.isRunning,
                title: "MCP for Claude",
                detail: status.mcpDetail,
                detailTint: status.mcp.isFailure && status.database == .running ? .red : nil,
                action: { show(.mcp) }
            ) {
                mcpAction(status)
            }
            .accessibilityIdentifier("menubar.mcp")
        }
        .accessibilityIdentifier("menubar.services")
    }

    private func databaseDetail(_ status: MenuBarStatus) -> String {
        status.database == .running ? "Running on port \(String(appState.postgres.port))" : status.databaseDetail
    }

    @ViewBuilder
    private func databaseAction(_ status: MenuBarStatus) -> some View {
        switch status.database {
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .stopped, .failed:
            MenuBarActionButton(title: status.database == .stopped ? "Start" : "Retry") {
                Task { await appState.startPostgres() }
            }
            .accessibilityIdentifier("menubar.database.start")
        case .needsMigration:
            MenuBarActionButton(title: appState.isApplyingMigrations ? "Applying…" : "Apply", isDisabled: appState.isApplyingMigrations) {
                Task { await appState.applyMigrations() }
            }
            .accessibilityIdentifier("menubar.database.migrate")
        case .running:
            EmptyView()
        }
    }

    @ViewBuilder
    private func mcpAction(_ status: MenuBarStatus) -> some View {
        switch status.mcp {
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .stopped, .failed:
            if status.database == .running {
                MenuBarActionButton(title: status.mcp == .stopped ? "Start" : "Retry") {
                    Task { try? await appState.mcp.start() }
                }
                .accessibilityIdentifier("menubar.mcp.start")
            }
        case .running:
            EmptyView()
        }
    }

    // MARK: - Activity

    /// What the pipeline is doing, and the one action that fits: "Ingest Now" while idle, "Stop"
    /// while it runs. The module's title line doubles as the popover's status line.
    private func activityModule(_ status: MenuBarStatus) -> some View {
        MenuBarModule {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button {
                        show(.status)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status.tint)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(status.headline)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if let fraction = status.ingestFraction {
                                Text(MenuBarStatus.percent(fraction))
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuBarRowButtonStyle())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("menubar.status")

                    Spacer(minLength: 4)

                    activityAction(status)
                }

                if status.isBusy {
                    if let fraction = status.ingestFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    }
                    if let detail = status.activityDetail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    if let item = status.currentItem {
                        Text(MenuBarStatus.abbreviatedPath(item))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    MenuBarStageTrail(stages: status.stageTrail, current: status.stage)
                        .padding(.top, 2)
                } else if status.database == .running {
                    Text(status.corpusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(idleDetail(status))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(status.attentions.enumerated()), id: \.offset) { _, attention in
                    attentionRow(attention)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
        .accessibilityIdentifier("menubar.activity")
    }

    private func idleDetail(_ status: MenuBarStatus) -> String {
        switch status.database {
        case .stopped: "Start the database to search and ingest."
        case .starting: "Bringing up Postgres, MCP and the gRPC bridge."
        case .stopping: "Waiting for connections to close."
        case .needsMigration: "Apply the migration to bring the schema up to date."
        case .failed: "See the Database page for the log."
        case .running: status.corpusLine
        }
    }

    @ViewBuilder
    private func activityAction(_ status: MenuBarStatus) -> some View {
        switch status.activity {
        case .idle:
            if status.database == .running {
                MenuBarActionButton(title: "Ingest Now", isDisabled: !status.canIngest) {
                    Task { await appState.ingestAllSources() }
                }
                .help(status.sourceCount == 0 ? "Add a source in Garage first." : "Scan and ingest every source.")
                .accessibilityIdentifier("menubar.ingest")
            }
        case .ingesting:
            MenuBarActionButton(
                title: status.isCancellingIngest ? "Stopping…" : "Stop",
                isDestructive: true,
                isDisabled: status.isCancellingIngest
            ) {
                Task { await appState.cancelIngest() }
            }
            .accessibilityIdentifier("menubar.cancel")
        case .scanning:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                appState.cancelScan()
            }
            .accessibilityIdentifier("menubar.cancel")
        case .embedding:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                appState.backfill.cancel()
            }
            .accessibilityIdentifier("menubar.cancel")
        case .distilling:
            MenuBarActionButton(title: "Stop", isDestructive: true) {
                appState.enrichFacts.cancel()
            }
            .accessibilityIdentifier("menubar.cancel")
        }
    }

    /// One line per problem, with the page that explains it a click away. Database and MCP failures
    /// already colour their service row, so here they only get their "why"; a failed ingest has no
    /// row of its own and is the one people otherwise never learn about.
    @ViewBuilder
    private func attentionRow(_ attention: MenuBarStatus.Attention) -> some View {
        switch attention {
        case .ingestFailed(let message):
            attentionLine("Last ingest failed: \(message)", section: .logs)
        case .databaseFailed, .databaseNeedsMigration, .mcpFailed:
            EmptyView()
        }
    }

    private func attentionLine(_ text: String, section: AppSection) -> some View {
        Button {
            show(section)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
        .padding(.top, 2)
        .accessibilityIdentifier("menubar.attention")
    }

    // MARK: - Navigation

    private func show(_ section: AppSection) {
        MenuBarNavigation.show(section, openWindow: openWindow)
    }
}

private extension MenuBarStatus.Database {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private extension MenuBarStatus.Server {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
