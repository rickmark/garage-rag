import XCTest
import PythonXPCService

/// The database password file every Garage process reads: owner-only from the start, whole or
/// absent, and never mistaken for "no password" when it is unreadable or empty.
final class GaragePostgresPasswordFileTests: XCTestCase {
    private var folder: URL!
    private var file: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent("garage-password-\(UUID().uuidString)", isDirectory: true)
        file = folder.appendingPathComponent(GaragePostgresEndpoint.passwordFileName)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder)
    }

    private func mode(of url: URL) throws -> Int {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testAMissingFileIsNoPassword() throws {
        XCTAssertNil(try GaragePostgresEndpoint.readPassword(from: file))
    }

    func testWrittenPasswordIsOwnerOnlyAndReadsBack() throws {
        try GaragePostgresEndpoint.writePassword("s3cret", to: file)
        XCTAssertEqual(try mode(of: file), 0o600)
        XCTAssertEqual(try GaragePostgresEndpoint.readPassword(from: file), "s3cret")
    }

    func testWritingReplacesAndLeavesNoTemporaryFiles() throws {
        try GaragePostgresEndpoint.writePassword("first", to: file)
        try GaragePostgresEndpoint.writePassword("second", to: file)
        XCTAssertEqual(try GaragePostgresEndpoint.readPassword(from: file), "second")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [GaragePostgresEndpoint.passwordFileName])
    }

    func testALoosenedFileIsTightened() throws {
        try GaragePostgresEndpoint.writePassword("s3cret", to: file)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try GaragePostgresEndpoint.readPassword(from: file), "s3cret")
        XCTAssertEqual(try mode(of: file), 0o600)
    }

    func testAnEmptyFileIsAnErrorNotNoPassword() throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: file.path, contents: Data("\n".utf8)))
        XCTAssertThrowsError(try GaragePostgresEndpoint.readPassword(from: file))
    }

    func testThePasswordLivesInTheDataFolder() {
        XCTAssertEqual(
            GaragePostgresEndpoint.passwordFile,
            GarageAppGroup.dataDirectory.appendingPathComponent("postgres-password")
        )
    }
}
