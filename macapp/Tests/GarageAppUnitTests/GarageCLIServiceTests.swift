import XCTest
@testable import GarageApp

final class GarageCLIServiceTests: XCTestCase {

    func testGarageCommandResultSuccess() {
        let successResult = GarageCommandResult(exitCode: 0, lines: [])
        XCTAssertTrue(successResult.succeeded)
        XCTAssertEqual(successResult.exitCode, 0)

        let failureResult = GarageCommandResult(exitCode: 1, lines: [])
        XCTAssertFalse(failureResult.succeeded)
        XCTAssertEqual(failureResult.exitCode, 1)
    }

    @MainActor
    func testInitialState() {
        let postgres = PostgresService()
        let service = GarageCLIService(postgres: postgres, commandLabel: "test CLI")

        XCTAssertFalse(service.isRunning)
        XCTAssertTrue(service.logs.isEmpty)
    }

    @MainActor
    func testRunRejectionWhenCliNotFound() async {
        let postgres = PostgresService()
        let service = GarageCLIService(postgres: postgres, commandLabel: "test CLI")

        // In test environment, the bundled CLI might not exist at Paths.garageCLI
        if !service.cliAvailable {
            let result = await service.run(["version"])
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.exitCode, -1)
            XCTAssertFalse(service.logs.isEmpty)
            XCTAssertTrue(service.logs.contains { $0.text.contains("not found") })
        }
    }
}
