import XCTest
@testable import GarageApp

final class PathsTests: XCTestCase {

    func testAppSupportDirectoryContainsGarageApp() {
        let appSupport = Paths.appSupportDir
        XCTAssertTrue(appSupport.path.contains("GarageApp") || appSupport.path.contains("Library/Application Support"))
    }

    func testPgDataDirIsSubdirectoryOfAppSupport() {
        let pgData = Paths.pgDataDir
        XCTAssertEqual(pgData.lastPathComponent, "pgdata")
        XCTAssertEqual(pgData.deletingLastPathComponent().standardizedFileURL, Paths.appSupportDir.standardizedFileURL)
    }

    func testPgSocketDirIsSubdirectoryOfAppSupport() {
        let pgSocket = Paths.pgSocketDir
        XCTAssertEqual(pgSocket.lastPathComponent, "sockets")
        XCTAssertEqual(pgSocket.deletingLastPathComponent().standardizedFileURL, Paths.appSupportDir.standardizedFileURL)
    }

    func testLogsDirIsSubdirectoryOfAppSupport() {
        let logs = Paths.logsDir
        XCTAssertEqual(logs.lastPathComponent, "logs")
        XCTAssertEqual(logs.deletingLastPathComponent().standardizedFileURL, Paths.appSupportDir.standardizedFileURL)
    }

    func testSchemaDirName() {
        let schema = Paths.schemaDir
        XCTAssertEqual(schema.lastPathComponent, "schema")
    }

    func testPostgresToolPathResolution() {
        let initdb = Paths.postgresTool("initdb")
        XCTAssertEqual(initdb.lastPathComponent, "initdb")
        XCTAssertEqual(initdb.deletingLastPathComponent().lastPathComponent, "bin")

        let postgres = Paths.postgresTool("postgres")
        XCTAssertEqual(postgres.lastPathComponent, "postgres")

        let psql = Paths.postgresTool("psql")
        XCTAssertEqual(psql.lastPathComponent, "psql")
    }

    func testPostgresBinDirIsSubdirectoryOfPostgresDir() {
        let binDir = Paths.postgresBinDir
        XCTAssertEqual(binDir.lastPathComponent, "bin")
        XCTAssertEqual(binDir.deletingLastPathComponent().standardizedFileURL, Paths.postgresDir.standardizedFileURL)
    }

    func testPostgresLibDirIsSubdirectoryOfPostgresDir() {
        let libDir = Paths.postgresLibDir
        XCTAssertEqual(libDir.lastPathComponent, "lib")
        XCTAssertEqual(libDir.deletingLastPathComponent().standardizedFileURL, Paths.postgresDir.standardizedFileURL)
    }

    func testPostgresShareDirIsSubdirectoryOfPostgresDir() {
        let shareDir = Paths.postgresShareDir
        XCTAssertEqual(shareDir.lastPathComponent, "share")
        XCTAssertEqual(shareDir.deletingLastPathComponent().standardizedFileURL, Paths.postgresDir.standardizedFileURL)
    }

    func testPostgresConfigFileResolution() {
        let conf = Paths.postgresConfigFile
        XCTAssertTrue(conf.lastPathComponent == "postgresql.conf" || conf.lastPathComponent == "postgres.conf")
    }

    func testGarageCLIName() {
        let cli = Paths.garageCLI
        XCTAssertEqual(cli.lastPathComponent, "garage")
    }

    func testGarageMCPName() {
        let mcp = Paths.garageMCP
        XCTAssertEqual(mcp.lastPathComponent, "garage-mcp")
    }

    func testIsPackagedReturnsTrue() {
        XCTAssertTrue(Paths.isPackaged)
    }

    func testGarageWorkingDirectory() {
        let workDir = Paths.garageWorkingDirectory
        XCTAssertEqual(workDir.standardizedFileURL, Paths.appSupportDir.standardizedFileURL)
    }
}
