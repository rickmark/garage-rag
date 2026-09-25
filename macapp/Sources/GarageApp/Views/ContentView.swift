import SwiftUI
import AppKit
import PythonXPCService

enum AppSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case database = "Database"
    case sources = "Sources"
    case documents = "Documents"
    case models = "Models"
    case mcp = "MCP Server"
    case search = "Search"
    case logs = "Logs"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .status: "gauge.with.dots.needle.50percent"
        case .database: "cylinder.split.1x2"
        case .sources: "tray.and.arrow.down"
        case .documents: "doc.text.magnifyingglass"
        case .models: "cpu"
        case .mcp: "server.rack"
        case .search: "magnifyingglass"
        case .logs: "terminal"
        }
    }
}

struct ContentView: View {
    /// The modal dialogs the main window can put up. Modelled as one piece of
    /// state rather than a flag per sheet: SwiftUI presents a single sheet per
    /// view, and the bug reporter can be asked for while the splash is up.
    enum ActiveSheet: Identifiable, Equatable {
        case splash
        case bugReport(BugReportContext)

        var id: String {
            switch self {
            case .splash: "splash"
            case .bugReport: "bugReport"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @State private var selection: AppSection? = .status
    @State private var activeSheet: ActiveSheet?
    @State private var pendingPresentation: Task<Void, Never>?
    @AppStorage(SplashPreferences.showAtLaunchKey) private var showSplashAtLaunch = true
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if appState.firstRun.isActive {
                FirstRunView()
            } else {
                mainWindow
            }
        }
        .overlay(alignment: .bottomTrailing) {
            BugNub()
                .padding(.bottom, 48)
        }
        .background(WindowReader { resolved in
            window = resolved
            // Already showing the assistant when the window appears: a first launch, or the relaunch
            // after "Reset Database", which restores the last frame.
            // Not animated: the window is not on screen yet, so it should simply open at that size.
            if appState.firstRun.isActive {
                MainWindowSizing.sizeForFirstRun(resolved, animate: false)
            }
        })
        .onChange(of: appState.firstRun.isActive) { wasActive, isActive in
            // The assistant has its own size; the pages behind it want at least the working size.
            guard let window, wasActive != isActive else { return }
            if isActive {
                MainWindowSizing.sizeForFirstRun(window)
            } else {
                MainWindowSizing.growAfterFirstRun(window)
            }
        }
        .onAppear(perform: presentSplashAtLaunchIfNeeded)
        .onReceive(NotificationCenter.default.publisher(for: .garageShowSplash)) { _ in
            present(.splash)
        }
        .onReceive(NotificationCenter.default.publisher(for: .garageShowBugReport)) { notification in
            let context = (notification.object as? BugReportContext) ?? BugReportContext()
            present(.bugReport(context))
        }
        .onReceive(NotificationCenter.default.publisher(for: .garageWillQuit)) { _ in
            // Close through our own state first: tearing the window down in
            // AppKit while a sheet is up is what left the splash stranded.
            pendingPresentation?.cancel()
            pendingPresentation = nil
            activeSheet = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .garageShowFirstRun)) { _ in
            // The sender starts the assistant on `appState`; this window only
            // gets its sheets out of the way.
            pendingPresentation?.cancel()
            pendingPresentation = nil
            activeSheet = nil
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .splash: SplashView()
            case .bugReport(let context): BugReportView(context: context)
            }
        }
    }

    private var mainWindow: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
                    .accessibilityIdentifier("sidebar.\(section)")
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            switch selection ?? .status {
            case .status: StatusView(selection: $selection)
            case .database: DatabaseView()
            case .sources: SourcesView()
            case .documents: DocumentsView()
            case .models: ModelsView()
            case .mcp: MCPServerView()
            case .search: SearchView()
            case .logs: LogsView()
            }
        }
    }

    /// Swapping one sheet for another has to go through `nil`, otherwise
    /// AppKit is still tearing the first one down when the second is asked to
    /// appear and neither ends up on screen.
    ///
    /// Any deferred presentation is cancelled first: a second request
    /// arriving inside that window would otherwise be overwritten when the
    /// earlier task woke up and applied its now-stale sheet, reopening the
    /// wrong dialog or the wrong log context.
    private func present(_ sheet: ActiveSheet) {
        pendingPresentation?.cancel()
        pendingPresentation = nil

        guard let current = activeSheet, current != sheet else {
            activeSheet = sheet
            return
        }
        activeSheet = nil
        pendingPresentation = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            // `try?` swallows the cancellation error, so check it directly.
            guard !Task.isCancelled else { return }
            activeSheet = sheet
        }
    }

    /// Shows the splash once per launch unless the user turned it off (or we
    /// are running under XCTest, where a modal sheet would get in the way).
    /// The setup assistant takes the whole window on a fresh install, so the
    /// splash is skipped for that launch rather than stacked on top of it.
    private func presentSplashAtLaunchIfNeeded() {
        guard showSplashAtLaunch,
              !isRunningInTestEnvironment,
              // The app relaunched itself after "Reset Database"; it is not a new launch to greet.
              !CommandLine.arguments.contains(GarageAppLaunch.databaseResetArgument),
              !SplashLaunchGate.hasPresented else { return }
        SplashLaunchGate.hasPresented = true
        guard !appState.firstRun.isActive, !appState.firstRun.shouldPresentAtLaunch else { return }
        activeSheet = .splash
    }
}
