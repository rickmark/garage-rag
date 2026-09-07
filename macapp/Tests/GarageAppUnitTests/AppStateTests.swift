import XCTest
import SwiftUI
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
    func testOpenDatabaseInHandler() {
        let state = AppState()
        // Calling openDatabaseInHandler executes URL creation and attempts NSWorkspace open
        _ = state.openDatabaseInHandler()
        XCTAssertNotNil(state.lastCommandSucceeded)
        XCTAssertFalse(state.lastCommandOutput.isEmpty)
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
}
