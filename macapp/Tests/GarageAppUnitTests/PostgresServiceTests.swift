import XCTest
@testable import GarageApp

final class PostgresServiceTests: XCTestCase {

    @MainActor
    func testInitialStatusIsStopped() {
        let service = PostgresService()
        XCTAssertEqual(service.status, .stopped)
    }

    @MainActor
    func testDefaultPortAndDatabase() {
        let service = PostgresService()
        XCTAssertEqual(service.port, 14824)
        XCTAssertEqual(service.databaseName, "garage-rag")
    }

    @MainActor
    func testConnectionURLFormat() throws {
        let service = PostgresService()
        let url = try service.connectionURL()
        XCTAssertTrue(url.starts(with: "postgresql+psycopg://"))
        XCTAssertTrue(url.contains("@localhost:14824/garage-rag"))
    }

    func testPostgresStatusEquality() {
        XCTAssertEqual(PostgresStatus.stopped, PostgresStatus.stopped)
        XCTAssertEqual(PostgresStatus.starting, PostgresStatus.starting)
        XCTAssertEqual(PostgresStatus.running, PostgresStatus.running)
        XCTAssertEqual(PostgresStatus.stopping, PostgresStatus.stopping)
        XCTAssertEqual(PostgresStatus.failed("test"), PostgresStatus.failed("test"))
        XCTAssertNotEqual(PostgresStatus.failed("a"), PostgresStatus.failed("b"))
        XCTAssertNotEqual(PostgresStatus.stopped, PostgresStatus.running)
    }

    func testPostgresErrorDescriptions() {
        let initError = PostgresError.initFailed("init error output")
        XCTAssertTrue(initError.localizedDescription.contains("initdb failed"))
        XCTAssertTrue(initError.localizedDescription.contains("init error output"))

        let startError = PostgresError.startupTimeout
        XCTAssertTrue(startError.localizedDescription.contains("postgres did not report ready in time"))

        let otherError = PostgresError.other("custom failure message")
        XCTAssertEqual(otherError.localizedDescription, "custom failure message")
    }
}
