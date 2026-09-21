import XCTest
import SwiftUI
import IngestClient
import ModelDownloadClient
@testable import GarageApp

final class AppStateTests: XCTestCase {

    @MainActor
    func testInitialState() {
        let state = AppState()

        XCTAssertTrue(state.autoStartPostgres)
        XCTAssertEqual(state.lastCommandOutput, "")
        XCTAssertNil(state.lastCommandSucceeded)
        XCTAssertEqual(state.postgres.status, .stopped)
        XCTAssertNotNil(state.llama)
        XCTAssertFalse(state.llama.isConnected)
    }

    @MainActor
    func testStatusSummaryMapping() {
        let state = AppState()

        XCTAssertEqual(state.statusSummary, "Stopped")
        XCTAssertEqual(state.statusColor, .secondary)
    }

    @MainActor
    func testScheduledMaintenanceDefaultInterval() {
        let state = AppState()
        XCTAssertGreaterThan(state.scheduledMaintenanceInterval, 0)
    }

    @MainActor
    func testSaveLMStudioTokenValidation() {
        let state = AppState()

        // Empty token should set failure and proper output message
        let result = state.saveLMStudioToken("   ")
        XCTAssertFalse(result)
        XCTAssertEqual(state.lastCommandSucceeded, false)
        XCTAssertEqual(state.lastCommandOutput, "LM Studio API token must not be empty.")
    }

    @MainActor
    func testRemoveLMStudioTokenSetsMessage() {
        let state = AppState()
        state.removeLMStudioToken()

        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertEqual(state.lastCommandOutput, "LM Studio API token removed from Keychain.")
        XCTAssertFalse(state.lmStudioTokenConfigured)
    }

    @MainActor
    func testRunGarageWhenCliUnavailable() async {
        let state = AppState()

        let result = await state.runGarage(["status"])
        // If CLI is not found or fails
        XCTAssertEqual(result, state.lastCommandSucceeded ?? false)
    }

    @MainActor
    func testVolumeAccessIntegration() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/System")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        let testResult = state.testVolumeAccess()
        XCTAssertTrue(testResult.isAccessible)
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertTrue(state.lastCommandOutput.contains("Full volume access verified"))

        state.revokeVolumeAccess()
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertEqual(state.lastCommandOutput, "Volume access revoked and saved bookmark cleared.")
        XCTAssertEqual(state.volumeAccess.status, .notConfigured)
    }

    @MainActor
    func testModelDownloadTaskInfoWithModelId() {
        let task = DownloadTaskInfo(
            url: "https://example.com/bge-m3.gguf",
            filename: "bge-m3.gguf",
            destinationPath: "/tmp/bge-m3.gguf",
            modelId: "BAAI/bge-m3"
        )
        XCTAssertEqual(task.modelId, "BAAI/bge-m3")
        XCTAssertEqual(task.filename, "bge-m3.gguf")
        XCTAssertEqual(task.status, .queued)
    }

    @MainActor
    func testRegisteredSourcesInitialAndFetch() async {
        let state = AppState()
        XCTAssertTrue(state.registeredSources.isEmpty)
        XCTAssertFalse(state.isFetchingSources)

        await state.fetchRegisteredSources()
        // Should complete without error and update isFetchingSources to false
        XCTAssertFalse(state.isFetchingSources)
    }

    @MainActor
    func testPresetModelsInitialization() {
        let state = AppState()
        XCTAssertFalse(state.presetModels.isEmpty)
        XCTAssertTrue(state.presetModels.contains { $0.slug == "bge-m3" })
        XCTAssertTrue(state.presetModels.contains { $0.slug == "nomic-embed-text" })
    }

    @MainActor
    func testVolumeAccessPassesSourcePaths() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let sourcePath = "/Users/test/Dropbox"
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", sourcePath]
        mockFS.directoryContents = [URL(fileURLWithPath: "\(sourcePath)/file1.txt")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        let result = state.testVolumeAccess()
        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(state.lastCommandSucceeded, true)
    }

    @MainActor
    func testCopyDatabaseURLToClipboard() {
        let state = AppState()
        let result = state.copyDatabaseURLToClipboard()
        XCTAssertTrue(result)
        XCTAssertEqual(state.lastCommandSucceeded, true)
        XCTAssertTrue(state.lastCommandOutput.contains("Copied PostgreSQL connection URL to clipboard:"))
        let clipboardContent = NSPasteboard.general.string(forType: .string)
        XCTAssertTrue(clipboardContent?.starts(with: "postgresql://") == true)
    }

    @MainActor
    func testResetDatabaseUpdatesState() async {
        let state = AppState()
        await state.resetDatabase()
        XCTAssertNotNil(state.lastCommandSucceeded)
        XCTAssertFalse(state.lastCommandOutput.isEmpty)
    }

    @MainActor
    func testAppStateTCCConvenienceMethods() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [URL(fileURLWithPath: "/System")]

        let volumeService = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let state = AppState(llama: LlamaService(), volumeAccess: volumeService)

        // Test openPrivacySettings invocation (does not crash or throw)
        state.openPrivacySettings(for: .messages)
        state.openPrivacySettings(for: .mail)
        state.openPrivacySettings(for: .fullDiskAccess)
    }

    @MainActor
    func testMigrationInitialStateAndMethods() async {
        let state = AppState()
        XCTAssertFalse(state.isApplyingMigrations)
        XCTAssertTrue(state.postgres.pendingMigrations.isEmpty)

        state.checkPendingMigrations()
        XCTAssertTrue(state.postgres.pendingMigrations.isEmpty)

        // Calling applyMigrations when postgres is stopped should return early without hanging or crashing
        await state.applyMigrations()
        XCTAssertFalse(state.isApplyingMigrations)
    }

    @MainActor
    func testBackfillExecutionAndLogs() async {
        let state = AppState()
        XCTAssertFalse(state.backfill.isRunning)
        XCTAssertTrue(state.backfill.logs.isEmpty)

        // Running backfill when CLI is not running
        _ = await state.runBackfill(["backfill", "--model", "test-model"])
        XCTAssertFalse(state.backfill.isRunning)

        // Clear logs for backfill
        state.clearLogs(for: "Backfill")
        XCTAssertTrue(state.backfill.logs.isEmpty)
    }

    @MainActor
    func testCombinedIngestLogsCombinesAndOrdersLogs() {
        let state = AppState()

        let now = Date()
        let line1 = LogLine(date: now.addingTimeInterval(-10), stream: .stdout, text: "CLI Ingest Line 1", source: "ingest")
        let line2 = LogLine(date: now.addingTimeInterval(-5), stream: .stdout, text: "XPC Ingest Line 2", source: "ingest-xpc")
        let line3 = LogLine(date: now, stream: .stdout, text: "CLI Ingest Line 3", source: "ingest")

        state.ingest.appendLog(line1.text)
        state.ingestService.appendLog(line2.text)
        state.ingest.appendLog(line3.text)

        let combined = state.combinedIngestLogs
        XCTAssertEqual(combined.count, 3)
        XCTAssertTrue(combined.contains { $0.text == "CLI Ingest Line 1" })
        XCTAssertTrue(combined.contains { $0.text == "XPC Ingest Line 2" })
        XCTAssertTrue(combined.contains { $0.text == "CLI Ingest Line 3" })

        // Check chronological ordering
        for i in 0..<(combined.count - 1) {
            XCTAssertLessThanOrEqual(combined[i].date, combined[i + 1].date)
        }
    }

    @MainActor
    func testClearLogsForIngestClearsBothStreams() {
        let state = AppState()

        state.ingest.appendLog("CLI log")
        state.ingestService.appendLog("XPC log")

        XCTAssertFalse(state.ingest.logs.isEmpty)
        XCTAssertFalse(state.ingestService.logs.isEmpty)
        XCTAssertFalse(state.combinedIngestLogs.isEmpty)

        state.clearLogs(for: "Ingest")

        XCTAssertTrue(state.ingest.logs.isEmpty)
        XCTAssertTrue(state.ingestService.logs.isEmpty)
        XCTAssertTrue(state.combinedIngestLogs.isEmpty)
    }

    @MainActor
    func testXPCServiceManagerLogsAndClear() async {
        let state = AppState()

        state.xpcServices.appendLog("Test XPC log line", source: "llama-xpc", level: .info)
        XCTAssertEqual(state.xpcServices.logs.count, 1)
        XCTAssertEqual(state.xpcServices.logs.first?.text, "Test XPC log line")
        XCTAssertEqual(state.xpcServices.logs.first?.source, "llama-xpc")

        state.clearLogs(for: "XPC Services")
        XCTAssertTrue(state.xpcServices.logs.isEmpty)
    }

    @MainActor
    func testCombinedIngestProgressUsesPriorScanTotalsAcrossSources() {
        let state = AppState()

        let source1 = RegisteredSource(slug: "source-a", root: "/tmp/a", expectedElements: 100)
        let source2 = RegisteredSource(slug: "source-b", root: "/tmp/b", expectedElements: 300)
        let source3 = RegisteredSource(slug: "source-c", root: "/tmp/c", expectedElements: 600)
        state.registeredSources = [source1, source2, source3]
        state.corpusStats.totalExpectedElements = 1000

        state.ingestService.setPendingSources(["source-a", "source-b", "source-c"])
        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 0)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.0)
        XCTAssertEqual(state.combinedIngestProgressPercent, "0%")

        // Source 1 starts and reports 50 items seen
        state.ingestService.markSourceActive("source-a")
        let prog1Active = IngestProgressUpdate(
            source: "source-a",
            phase: "ingest",
            seen: 50,
            totalItems: 100,
            indexed: 45,
            skipped: 5,
            failed: 0,
            placeholders: 0,
            chunksWritten: 90,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting source-a: 50/100",
            error: nil,
            currentItem: "file1.txt"
        )
        state.ingestService.handleProgress(prog1Active)

        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 50)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.05, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "5%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 45)
        XCTAssertEqual(state.combinedIngestSkippedCount, 5)

        // Source 1 completes
        let prog1Complete = IngestProgressUpdate(
            source: "source-a",
            phase: "complete",
            seen: 100,
            totalItems: 100,
            indexed: 95,
            skipped: 5,
            failed: 0,
            placeholders: 0,
            chunksWritten: 190,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-a",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog1Complete)

        // Source 2 starts and reports 150 items seen
        state.ingestService.markSourceActive("source-b")
        let prog2Active = IngestProgressUpdate(
            source: "source-b",
            phase: "ingest",
            seen: 150,
            totalItems: 300,
            indexed: 150,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 300,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting source-b: 150/300",
            error: nil,
            currentItem: "file2.txt"
        )
        state.ingestService.handleProgress(prog2Active)

        // Combined should be 100 (from completed source-a) + 150 (from active source-b) = 250 / 1000 = 25%
        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 250)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "25%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 245)

        // Source 2 completes
        let prog2Complete = IngestProgressUpdate(
            source: "source-b",
            phase: "complete",
            seen: 300,
            totalItems: 300,
            indexed: 300,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 600,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-b",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog2Complete)

        // Source 3 starts and reports 600 items seen
        state.ingestService.markSourceActive("source-c")
        let prog3Complete = IngestProgressUpdate(
            source: "source-c",
            phase: "complete",
            seen: 600,
            totalItems: 600,
            indexed: 590,
            skipped: 10,
            failed: 0,
            placeholders: 0,
            chunksWritten: 1200,
            itemType: "documents",
            progress: 1.0,
            message: "Completed source-c",
            error: nil,
            currentItem: nil
        )
        state.ingestService.handleProgress(prog3Complete)

        XCTAssertEqual(state.combinedIngestTotalExpected, 1000)
        XCTAssertEqual(state.combinedIngestProcessedCount, 1000)
        XCTAssertEqual(state.combinedIngestProgressFraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "100%")
        XCTAssertEqual(state.combinedIngestIndexedCount, 985)
        XCTAssertEqual(state.combinedIngestSkippedCount, 15)
    }

    @MainActor
    func testCombinedIngestProgressSingleSourceWithPriorScan() {
        let state = AppState()

        let source = RegisteredSource(slug: "manual-docs", root: "/tmp/docs", expectedElements: 500)
        state.registeredSources = [source]
        state.corpusStats.totalExpectedElements = 500

        let prog = IngestProgressUpdate(
            source: "manual-docs",
            phase: "ingest",
            seen: 250,
            totalItems: 500,
            indexed: 240,
            skipped: 10,
            failed: 0,
            placeholders: 0,
            chunksWritten: 480,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting manual-docs: 250/500",
            error: nil,
            currentItem: "chapter1.pdf"
        )
        state.ingestService.handleProgress(prog)

        XCTAssertEqual(state.combinedIngestTotalExpected, 500)
        XCTAssertEqual(state.combinedIngestProcessedCount, 250)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "50%")
    }

    @MainActor
    func testCombinedIngestProgressFallbackWhenNoPriorScan() {
        let state = AppState()

        let source = RegisteredSource(slug: "unscanned", root: "/tmp/unscanned", expectedElements: 0)
        state.registeredSources = [source]
        state.corpusStats.totalExpectedElements = 0

        let prog = IngestProgressUpdate(
            source: "unscanned",
            phase: "ingest",
            seen: 20,
            totalItems: 40,
            indexed: 20,
            skipped: 0,
            failed: 0,
            placeholders: 0,
            chunksWritten: 40,
            itemType: "documents",
            progress: 0.5,
            message: "Ingesting unscanned: 20/40",
            error: nil,
            currentItem: "file.txt"
        )
        state.ingestService.handleProgress(prog)

        XCTAssertEqual(state.combinedIngestTotalExpected, 40)
        XCTAssertEqual(state.combinedIngestProcessedCount, 20)
        XCTAssertEqual(state.combinedIngestProgressFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(state.combinedIngestProgressPercent, "50%")
    }
}
