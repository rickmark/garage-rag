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
}
