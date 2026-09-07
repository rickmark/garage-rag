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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedUser = NSUserName().addingPercentEncoding(withAllowedCharacters: allowed) ?? NSUserName()
        XCTAssertTrue(url.starts(with: "postgresql+psycopg://\(encodedUser):"))
        XCTAssertFalse(url.contains("postgres-superuser"))
        XCTAssertFalse(url.contains("postgres-master"))
        XCTAssertTrue(url.contains("@localhost:14824/garage-rag"))
    }

    @MainActor
    func testConnectionURLUsesLoggedInUserNotPostgresSuperuser() throws {
        let service = PostgresService()
        let url = try service.connectionURL()
        let currentUser = NSUserName()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedUser = currentUser.addingPercentEncoding(withAllowedCharacters: allowed) ?? currentUser

        XCTAssertFalse(url.contains("postgres-superuser"))
        XCTAssertFalse(url.contains("postgres-master"))
        XCTAssertTrue(url.contains("://\(encodedUser):"))
    }

    @MainActor
    func testConnectionURLIsConsistentAcrossCalls() throws {
        let service = PostgresService()
        let url1 = try service.connectionURL()
        let url2 = try service.connectionURL()
        XCTAssertEqual(url1, url2)
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
