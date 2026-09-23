import XCTest
import PythonXPCService
@testable import GarageApp

/// `--data-directory` is what keeps a UI test's "Reset Database" away from the real cluster, so a
/// path that reaches real data must be refused rather than used or silently ignored.
final class GarageAppGroupTests: XCTestCase {
    private var root: URL!
    private var real: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("GarageAppGroupTests-\(UUID().uuidString)", isDirectory: true)
        real = root.appendingPathComponent("Group Containers/group/GarageApp", isDirectory: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func override(_ arguments: [String]) throws -> URL? {
        try GarageAppGroup.dataDirectoryOverride(in: ["GarageApp"] + arguments, realDirectories: [real])
    }

    func testNoArgumentMeansNoOverride() throws {
        XCTAssertNil(try override([]))
        XCTAssertNil(GarageAppGroup.dataDirectoryOverride, "the test host must run on the default folder")
    }

    func testAcceptsASeparateFolderThatDoesNotExistYet() throws {
        let isolated = root.appendingPathComponent("ui-test/data", isDirectory: true)
        let url = try override([GarageAppLaunch.dataDirectoryArgument, isolated.path])
        XCTAssertEqual(url?.path, isolated.standardizedFileURL.path)
    }

    func testRefusesAMissingOrRelativePath() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, "relative/data"]))
    }

    func testRefusesTheRealFolderAndAnythingInsideIt() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, real.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, real.appendingPathComponent("pgdata").path]))
    }

    func testRefusesAFolderThatContainsTheRealOne() {
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, root.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, "/"]))
    }

    /// `~/Library/Application Support/GarageApp` is a link to the group folder on Developer ID builds.
    func testRefusesAPathThatReachesTheRealFolderThroughALink() throws {
        let link = root.appendingPathComponent("Application Support/GarageApp", isDirectory: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, link.path]))
        XCTAssertThrowsError(try override([GarageAppLaunch.dataDirectoryArgument, link.appendingPathComponent("isolated").path]))
    }

    func testTheRealDirectoriesCoverEveryKnownLocation() {
        let paths = GarageAppGroup.realDataDirectories.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Application Support/GarageApp") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Group Containers/\(GarageAppGroup.identifier)") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Containers/me.rickmark.garage-rag") })
    }

    func testTheRealKeychainItemIsUsedWithoutAnOverride() {
        XCTAssertEqual(GaragePostgresEndpoint.keychainService, "com.rickmark.garage.postgres")
    }
}
