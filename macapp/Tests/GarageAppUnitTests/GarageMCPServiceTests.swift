import XCTest
@testable import GarageApp

final class GarageMCPServiceTests: XCTestCase {

    @MainActor
    func testInitialStateAndDefaults() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres, defaults: defaults)

        XCTAssertEqual(mcp.status, .stopped)
        XCTAssertEqual(mcp.host, "127.0.0.1")
        XCTAssertEqual(mcp.port, 8787)
        XCTAssertEqual(mcp.path, "/mcp")
        XCTAssertEqual(mcp.endpoint.absoluteString, "http://127.0.0.1:8787/mcp")
        XCTAssertTrue(mcp.logs.isEmpty)
    }

    @MainActor
    func testCustomPortAndUserDefaultsPersistence() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()

        let mcp1 = GarageMCPService(postgres: postgres, port: 9000, defaults: defaults)
        XCTAssertEqual(mcp1.port, 9000)
        XCTAssertEqual(mcp1.endpoint.absoluteString, "http://127.0.0.1:9000/mcp")

        mcp1.port = 9001
        XCTAssertEqual(mcp1.port, 9001)
        XCTAssertEqual(mcp1.endpoint.absoluteString, "http://127.0.0.1:9001/mcp")
        XCTAssertEqual(defaults.integer(forKey: GarageMCPService.portDefaultsKey), 9001)

        let mcp2 = GarageMCPService(postgres: postgres, defaults: defaults)
        XCTAssertEqual(mcp2.port, 9001)
        XCTAssertEqual(mcp2.endpoint.absoluteString, "http://127.0.0.1:9001/mcp")
    }

    @MainActor
    func testSelectRandomPort() {
        let suiteName = "GarageMCPServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let postgres = PostgresService()
        let mcp = GarageMCPService(postgres: postgres, port: 8787, defaults: defaults)

        let initialPort = mcp.port
        let newPort = mcp.selectRandomPort()

        XCTAssertNotEqual(newPort, initialPort)
        XCTAssertEqual(mcp.port, newPort)
        XCTAssertTrue((1024...65535).contains(newPort))
        XCTAssertEqual(mcp.endpoint.absoluteString, "http://127.0.0.1:\(newPort)/mcp")
        XCTAssertEqual(defaults.integer(forKey: GarageMCPService.portDefaultsKey), newPort)
    }

    func testRandomPortExclusion() {
        let excluded: Set<Int> = [1024, 8787, 9000]
        for _ in 0..<100 {
            let port = GarageMCPService.randomPort(excluding: excluded)
            XCTAssertFalse(excluded.contains(port))
            XCTAssertTrue((1024...65535).contains(port))
        }
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
