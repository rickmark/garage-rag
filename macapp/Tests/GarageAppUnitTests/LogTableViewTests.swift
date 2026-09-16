import XCTest
import SwiftUI
@testable import GarageApp

final class LogTableViewTests: XCTestCase {

    func testLogLevelOrderingAndComparison() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertEqual(LogLevel.allCases.count, 4)
    }

    func testLogLevelInferencing() {
        let errorLine = LogLine(stream: .stdout, text: "FATAL: database cluster corrupted", source: "postgres")
        XCTAssertEqual(errorLine.level, .error)

        let panicLine = LogLine(stream: .stdout, text: "panic: runtime error: index out of range", source: "app")
        XCTAssertEqual(panicLine.level, .error)

        let tracebackLine = LogLine(stream: .stdout, text: "Traceback (most recent call last):", source: "python")
        XCTAssertEqual(tracebackLine.level, .error)

        let warnLine = LogLine(stream: .stdout, text: "[WARN] high memory consumption detected", source: "garage")
        XCTAssertEqual(warnLine.level, .warning)

        let warningLine = LogLine(stream: .stdout, text: "WARNING: relation does not exist", source: "postgres")
        XCTAssertEqual(warningLine.level, .warning)

        let debugLine = LogLine(stream: .stdout, text: "[DEBUG] fetching 100 vector embeddings", source: "llama")
        XCTAssertEqual(debugLine.level, .debug)

        let infoLine = LogLine(stream: .stdout, text: "server started on port 14824", source: "postgres")
        XCTAssertEqual(infoLine.level, .info)

        let stderrLine = LogLine(stream: .stderr, text: "something failed", source: "cli")
        XCTAssertEqual(stderrLine.level, .error)

        let explicitOverride = LogLine(stream: .stdout, text: "just a notice", source: "custom", level: .warning)
        XCTAssertEqual(explicitOverride.level, .warning)
    }

    func testLogLineSearchMatching() {
        let line = LogLine(stream: .stdout, text: "vacuum analyze completed", source: "postgres-worker")

        XCTAssertTrue(line.matches(searchText: ""))
        XCTAssertTrue(line.matches(searchText: "vacuum"))
        XCTAssertTrue(line.matches(searchText: "VACUUM"))
        XCTAssertTrue(line.matches(searchText: "worker"))
        XCTAssertTrue(line.matches(searchText: "stdout"))
        XCTAssertTrue(line.matches(searchText: "info"))
        XCTAssertFalse(line.matches(searchText: "nonexistent_token_xyz"))
    }

    func testLogLevelFilterMatching() {
        XCTAssertTrue(LogLevelFilter.all.matches(.debug))
        XCTAssertTrue(LogLevelFilter.all.matches(.error))

        XCTAssertTrue(LogLevelFilter.error.matches(.error))
        XCTAssertFalse(LogLevelFilter.error.matches(.warning))

        XCTAssertTrue(LogLevelFilter.warning.matches(.warning))
        XCTAssertFalse(LogLevelFilter.warning.matches(.info))

        XCTAssertTrue(LogLevelFilter.info.matches(.info))
        XCTAssertFalse(LogLevelFilter.info.matches(.debug))

        XCTAssertTrue(LogLevelFilter.debug.matches(.debug))
        XCTAssertFalse(LogLevelFilter.debug.matches(.error))

        XCTAssertTrue(LogLevelFilter.warningsAndErrors.matches(.warning))
        XCTAssertTrue(LogLevelFilter.warningsAndErrors.matches(.error))
        XCTAssertFalse(LogLevelFilter.warningsAndErrors.matches(.info))
        XCTAssertFalse(LogLevelFilter.warningsAndErrors.matches(.debug))
    }

    func testLogStreamFilterMatching() {
        XCTAssertTrue(LogStreamFilter.all.matches(.stdout))
        XCTAssertTrue(LogStreamFilter.all.matches(.stderr))

        XCTAssertTrue(LogStreamFilter.stdout.matches(.stdout))
        XCTAssertFalse(LogStreamFilter.stdout.matches(.stderr))

        XCTAssertTrue(LogStreamFilter.stderr.matches(.stderr))
        XCTAssertFalse(LogStreamFilter.stderr.matches(.stdout))
    }

    func testLogTableViewFilteredLines() {
        let lines: [LogLine] = [
            LogLine(stream: .stdout, text: "Starting server", source: "app", level: .info),
            LogLine(stream: .stdout, text: "Memory cache warming", source: "app", level: .debug),
            LogLine(stream: .stdout, text: "Connection pool exhausted", source: "db", level: .warning),
            LogLine(stream: .stderr, text: "Crash in worker process", source: "worker", level: .error),
        ]

        let view = LogTableView(lines: lines, sourceName: "TestApp")
        XCTAssertEqual(view.filteredLines.count, 4)
    }

    @MainActor
    func testLogTableViewHosting() {
        let lines = [
            LogLine(stream: .stdout, text: "Sample log line 1", source: "test"),
            LogLine(stream: .stderr, text: "Sample error line 2", source: "test"),
        ]
        let view = LogTableView(lines: lines, sourceName: "TestService", onClear: {})
        let hostingController = NSHostingController(rootView: view)
        XCTAssertNotNil(hostingController.view)
    }

    @MainActor
    func testAppStateClearLogs() {
        let appState = AppState()
        appState.clearLogs(for: "Postgres")
        appState.clearLogs(for: "garage CLI")
        appState.clearLogs(for: "Ingest")
        appState.clearLogs(for: "Backfill")
        appState.clearLogs(for: "MCP Server")
        appState.clearLogs(for: "Llama Service")
        appState.clearLogs(for: "Model Downloader")
        appState.clearLogs(for: "Unified Log")

        XCTAssertTrue(appState.postgres.logs.isEmpty)
        XCTAssertTrue(appState.garage.logs.isEmpty)
        XCTAssertTrue(appState.ingest.logs.isEmpty)
        XCTAssertTrue(appState.backfill.logs.isEmpty)
        XCTAssertTrue(appState.mcp.logs.isEmpty)
        XCTAssertTrue(appState.llama.logs.isEmpty)
        XCTAssertTrue(appState.osLogStreamService.logs.isEmpty)
    }

    @MainActor
    func testOSLogStreamServiceOperations() {
        let streamer = OSLogStreamService(startStreaming: false)
        XCTAssertFalse(streamer.isStreaming)
        XCTAssertFalse(streamer.isPaused)

        // Test appending log entries for specific targets
        let line1 = LogLine(stream: .stdout, text: "Ingest completed for 10 docs", source: "IngestService", level: .info)
        streamer.appendLog(line1, for: [.ingest, .unifiedLog])
        XCTAssertEqual(streamer.logs(for: .ingest).count, 1)
        XCTAssertEqual(streamer.logs(for: .unifiedLog).count, 1)
        XCTAssertEqual(streamer.logs(for: .llama).count, 0)
        XCTAssertEqual(streamer.logs(for: .ingest).first?.text, "Ingest completed for 10 docs")

        // Test deduplication
        streamer.appendLog(line1, for: [.ingest, .unifiedLog])
        XCTAssertEqual(streamer.logs(for: .ingest).count, 1)

        // Test scope filters
        XCTAssertEqual(OSLogScopeFilter.allCases.count, 4)
        streamer.scopeFilter = .ingest
        XCTAssertEqual(streamer.scopeFilter, .ingest)
        XCTAssertNotNil(streamer.scopeFilter.predicate)

        // Test time windows
        XCTAssertEqual(OSLogTimeWindow.allCases.count, 5)
        XCTAssertEqual(OSLogTimeWindow.recent5m.interval, 300)

        // Test streaming controls
        streamer.startStreaming(since: Date().addingTimeInterval(-60))
        XCTAssertTrue(streamer.isStreaming)
        XCTAssertFalse(streamer.isPaused)

        streamer.pauseStreaming()
        XCTAssertTrue(streamer.isPaused)

        streamer.resumeStreaming()
        XCTAssertFalse(streamer.isPaused)

        streamer.togglePause()
        XCTAssertTrue(streamer.isPaused)

        streamer.togglePause()
        XCTAssertFalse(streamer.isPaused)

        streamer.stopStreaming()
        XCTAssertFalse(streamer.isStreaming)

        // Test per-source clear and fetch
        streamer.clearLogs(for: .ingest)
        XCTAssertTrue(streamer.logs(for: .ingest).isEmpty)
        XCTAssertFalse(streamer.logs(for: .unifiedLog).isEmpty)

        streamer.clearLogs()
        XCTAssertTrue(streamer.logs(for: .unifiedLog).isEmpty)
    }

    func testLogsViewSourceScopeMapping() {
        XCTAssertEqual(LogsView.LogSource.postgres.matchingOSLogScope, .system)
        XCTAssertEqual(LogsView.LogSource.garage.matchingOSLogScope, .all)
        XCTAssertEqual(LogsView.LogSource.ingest.matchingOSLogScope, .ingest)
        XCTAssertEqual(LogsView.LogSource.xpcServices.matchingOSLogScope, .xpc)
        XCTAssertEqual(LogsView.LogSource.unifiedLog.matchingOSLogScope, .all)
        XCTAssertNil(LogsView.LogSource.llama.matchingOSLogScope)
    }
}
