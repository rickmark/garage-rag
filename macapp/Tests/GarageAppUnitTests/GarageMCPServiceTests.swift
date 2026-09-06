import XCTest
@testable import GarageApp

final class GarageMCPServiceTests: XCTestCase {

    @MainActor
    func testInitialStateAndDefaults() {
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres)

        XCTAssertEqual(mcp.status, .stopped)
        XCTAssertEqual(mcp.host, "127.0.0.1")
        XCTAssertEqual(mcp.port, 8787)
        XCTAssertEqual(mcp.path, "/mcp")
        XCTAssertEqual(mcp.endpoint.absoluteString, "http://127.0.0.1:8787/mcp")
        XCTAssertTrue(mcp.logs.isEmpty)
    }

    func testGarageMCPStatusEquality() {
        XCTAssertEqual(GarageMCPStatus.stopped, GarageMCPStatus.stopped)
        XCTAssertEqual(GarageMCPStatus.starting, GarageMCPStatus.starting)
        XCTAssertEqual(GarageMCPStatus.running, GarageMCPStatus.running)
        XCTAssertEqual(GarageMCPStatus.stopping, GarageMCPStatus.stopping)
        XCTAssertEqual(GarageMCPStatus.failed("error"), GarageMCPStatus.failed("error"))
        XCTAssertNotEqual(GarageMCPStatus.failed("a"), GarageMCPStatus.failed("b"))
        XCTAssertNotEqual(GarageMCPStatus.stopped, GarageMCPStatus.running)
    }

    func testGarageMCPErrorDescriptions() {
        let cliError = GarageMCPError.cliNotFound
        XCTAssertTrue(cliError.localizedDescription.contains("garage CLI not found"))

        let timeoutError = GarageMCPError.startupTimeout
        XCTAssertTrue(timeoutError.localizedDescription.contains("did not become ready"))

        let launchError = GarageMCPError.launchFailed("permission denied")
        XCTAssertTrue(launchError.localizedDescription.contains("permission denied"))
    }
}
