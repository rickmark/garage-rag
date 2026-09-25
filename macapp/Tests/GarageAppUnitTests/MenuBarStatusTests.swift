import XCTest
@testable import GarageApp

final class MenuBarStatusTests: XCTestCase {

    func testIdleRunningDatabaseShowsTheCylinderAndReady() {
        let status = MenuBarStatus(database: .running, activity: .idle)
        XCTAssertEqual(status.symbol, "cylinder.split.1x2")
        XCTAssertEqual(status.headline, "Ready")
        XCTAssertNil(status.menuBarText)
        XCTAssertFalse(status.isBusy)
        XCTAssertFalse(status.needsAttention)
    }

    func testIngestFillsTheCylinderAndShowsItsPercentage() {
        let status = MenuBarStatus(database: .running, activity: .ingesting(source: "notes", fraction: 0.424))
        XCTAssertEqual(status.symbol, "cylinder.split.1x2.fill")
        XCTAssertEqual(status.menuBarText, "42%")
        XCTAssertEqual(status.headline, "Ingesting notes…")
    }

    func testIngestWithoutProgressYetShowsNoPercentage() {
        let status = MenuBarStatus(database: .running, activity: .ingesting(source: "", fraction: nil))
        XCTAssertNil(status.menuBarText)
        XCTAssertEqual(status.headline, "Ingesting…")
    }

    func testOtherWorkFillsTheCylinderWithoutText() {
        for activity in [MenuBarStatus.Activity.scanning, .embedding, .distilling] {
            let status = MenuBarStatus(database: .running, activity: activity)
            XCTAssertEqual(status.symbol, "cylinder.split.1x2.fill", "\(activity)")
            XCTAssertNil(status.menuBarText, "\(activity)")
        }
    }

    func testStoppedDatabaseShowsAnEmptyCylinder() {
        let status = MenuBarStatus(database: .stopped, activity: .idle)
        XCTAssertEqual(status.symbol, "cylinder")
        XCTAssertEqual(status.headline, "Database stopped")
    }

    func testFailureAndMigrationNeedAttention() {
        for database in [MenuBarStatus.Database.failed("port in use"), .needsMigration] {
            let status = MenuBarStatus(database: database, activity: .idle)
            XCTAssertTrue(status.needsAttention)
            XCTAssertEqual(status.symbol, "exclamationmark.triangle")
        }
    }

    func testDatabaseStateWinsOverActivityInTheHeadline() {
        let status = MenuBarStatus(database: .stopping, activity: .ingesting(source: "notes", fraction: 0.5))
        XCTAssertEqual(status.headline, "Stopping…")
    }

    func testPercentClamps() {
        XCTAssertEqual(MenuBarStatus.percent(-0.2), "0%")
        XCTAssertEqual(MenuBarStatus.percent(1.7), "100%")
    }

    @MainActor
    func testReadsAFreshAppStateAsStoppedAndIdle() {
        let status = MenuBarStatus(appState: AppState())
        XCTAssertEqual(status, MenuBarStatus(database: .stopped, activity: .idle))
    }
}
