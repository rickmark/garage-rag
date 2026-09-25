import AppKit
import XCTest

/// The Database page: the schema is brought up to date without a click, and the reset sheet's
/// Cancel leaves the database alone.
final class DatabaseUITests: GarageUITestCase {

    func testFreshClusterShowsSchemaUpToDate() throws {
        try launchApp()
        waitForBackend()

        open(section: "database")
        XCTAssertTrue(element(text: "Schema up to date").waitForExistence(timeout: 60), "a new cluster did not report its schema up to date")
        XCTAssertFalse(element(textBeginningWith: "Database reset").exists, "a normal launch reported a reset")
    }

    /// Takes one applied migration out of `schema_migrations`, restarts Garage on the same folder,
    /// and checks that start-up applied it again on its own.
    func testPendingMigrationIsAppliedAutomaticallyAtStart() throws {
        try launchApp()
        waitForBackend()

        let latest = try XCTUnwrap(try psql("SELECT max(version) FROM schema_migrations;"), "no applied migrations")
        XCTAssertFalse(latest.isEmpty, "schema_migrations is empty")
        _ = try psql("DELETE FROM schema_migrations WHERE version = '\(latest)';")
        XCTAssertEqual(try psql("SELECT count(*) FROM schema_migrations WHERE version = '\(latest)';"), "0")

        quitApp()
        try launchApp()
        waitForBackend()

        XCTAssertTrue(
            waitUntil(timeout: 60) { (try? self.psql("SELECT count(*) FROM schema_migrations WHERE version = '\(latest)';")) == "1" },
            "start-up did not re-apply \(latest)"
        )
        open(section: "database")
        XCTAssertTrue(element(text: "Schema up to date").waitForExistence(timeout: 30), "the Database page still reports missing migrations")
    }

    func testResetSheetCancelKeepsTheDatabase() throws {
        try launchApp()
        waitForBackend()
        let owner = try XCTUnwrap(appPID)
        let cluster = try clusterIdentity()

        open(section: "database")
        let reset = app.buttons["database.reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset Database… button")
        XCTAssertTrue(waitForEnabled(reset), "Reset Database… stayed disabled")
        reset.click()

        let cancel = app.buttons["reset.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the reset sheet did not open")
        XCTAssertTrue(app.buttons["reset.confirm"].exists, "the reset sheet has no confirm button")
        XCTAssertTrue(app.buttons["reset.backup"].exists, "the reset sheet does not offer a backup first")
        cancel.click()

        XCTAssertTrue(waitUntil(timeout: 10) { !cancel.exists }, "Cancel did not close the reset sheet")
        XCTAssertTrue(holds(for: 5) { self.postgresIsServing(from: owner) }, "Postgres stopped after Cancel")
        XCTAssertEqual(try clusterIdentity(), cluster, "Cancel replaced the cluster")
        XCTAssertEqual(appPID, owner, "Cancel relaunched Garage")
    }

    // MARK: - psql

    /// Runs one statement against this test's cluster with the app's bundled psql and returns the
    /// trimmed output (`-tA`: no headers, no alignment).
    private func psql(_ sql: String) throws -> String? {
        let pid = try XCTUnwrap(appPID, "no running Garage to find psql in")
        let bundle = try XCTUnwrap(NSRunningApplication(processIdentifier: pid)?.bundleURL)
        let postgres = bundle.appendingPathComponent("Contents/Resources/postgres", isDirectory: true)
        let password = try String(contentsOf: dataDirectory.appendingPathComponent("postgres-password"), encoding: .utf8)

        let process = Process()
        process.executableURL = postgres.appendingPathComponent("bin/psql")
        process.arguments = [
            "-h", postgresSocketDirectory ?? "localhost", "-p", String(Self.postgresPort),
            "-U", NSUserName(), "-d", "garage-rag",
            "-X", "-tA", "-v", "ON_ERROR_STOP=1", "-c", sql,
        ]
        process.environment = [
            "PGPASSWORD": password,
            "DYLD_LIBRARY_PATH": postgres.appendingPathComponent("lib").path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            XCTFail("psql failed (\(process.terminationStatus)): \(text)")
            return nil
        }
        return text
    }
}
