import XCTest
import SwiftUI
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
}
