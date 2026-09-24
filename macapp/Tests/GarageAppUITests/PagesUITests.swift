import XCTest

/// The Status, Models, Search, MCP Server and Logs pages on a new, empty corpus, and the bug
/// reporter reached from the window and from Logs.
final class PagesUITests: GarageUITestCase {

    func testStatusShowsOverviewAndServiceControls() throws {
        try launchApp()
        waitForBackend()
        open(section: "status")

        for heading in ["Corpus & Pipeline Overview", "Ingestion Status", "Chunk Embedding"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "Status does not show \"\(heading)\"")
        }
        XCTAssertTrue(element(text: "No documents indexed yet").waitForExistence(timeout: 30), "a new corpus does not say it has no documents")

        // Each XPC helper row offers Test and Restart; the separate Ping button is gone.
        XCTAssertTrue(button(label: "Restart").waitForExistence(timeout: 30), "no XPC service row with Restart")
        XCTAssertTrue(button(label: "Test").exists, "no XPC service row with Test")
        XCTAssertFalse(button(label: "Ping").exists, "the Status page still has a Ping button")
    }

    func testModelsToolbarOnAnEmptyRegistry() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        let refresh = element(identifier: "models.refresh")
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "no models refresh button")
        XCTAssertTrue(waitForEnabled(refresh), "the models refresh button stayed disabled")
        refresh.click()

        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(embedAll.exists, "no Embed All button")
        XCTAssertFalse(embedAll.isEnabled, "Embed All is enabled with no registered models")
        // ("Refresh" stays: the Llama section's status refresh still uses it.)
        for retired in ["Backfill All (*)", "Backfill", "Verify All SHA-256"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    func testSearchOnAnEmptyCorpusFindsNothing() throws {
        try launchApp()
        waitForBackend()
        open(section: "search")

        let query = element(identifier: "search.query")
        XCTAssertTrue(query.waitForExistence(timeout: 15), "no search field")
        // The plain-style field only takes focus when the click lands on its text area.
        query.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeText("system architecture\n")
        XCTAssertTrue(element(text: "No Results Found").waitForExistence(timeout: 60), "a search of an empty corpus did not end in No Results Found")
        XCTAssertFalse(element(text: "Search Failed").exists, "a search of an empty corpus failed")
    }

    func testMCPServerPageShowsStatusAndControls() throws {
        try launchApp()
        waitForBackend()
        open(section: "mcp")

        for heading in ["MCP Server Status", "Server Configuration & Endpoints", "Client Integrations & Configuration"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "MCP Server does not show \"\(heading)\"")
        }
        for control in ["Start", "Stop", "Restart"] {
            XCTAssertTrue(button(label: control).exists, "MCP Server has no \(control) button")
        }
    }

    func testLogsReportBugOpensAndCancelsTheBugReporter() throws {
        try launchApp()
        open(section: "logs")

        XCTAssertTrue(element(text: "Log Source").waitForExistence(timeout: 15), "Logs has no source picker")
        let reportBug = element(identifier: "logs.reportBug")
        XCTAssertTrue(reportBug.waitForExistence(timeout: 10), "Logs has no Report Bug button")
        reportBug.click()
        assertBugReporterOpensAndCancels()
    }

    func testBugNubOpensTheBugReporter() throws {
        try launchApp()
        let nub = element(identifier: "bugNub")
        XCTAssertTrue(nub.waitForExistence(timeout: 15), "the window has no bug nub")
        nub.click()
        assertBugReporterOpensAndCancels()
    }

    private func assertBugReporterOpensAndCancels(file: StaticString = #filePath, line: UInt = #line) {
        let title = element(identifier: "bugReport.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the bug reporter did not open", file: file, line: line)
        // The preview sits in a collapsed disclosure group, so only the always-visible controls are checked.
        XCTAssertTrue(element(identifier: "bugReport.includeLogs").exists, "the bug reporter has no include-logs option", file: file, line: line)
        XCTAssertTrue(element(identifier: "bugReport.save").exists, "the bug reporter cannot save a report", file: file, line: line)
        XCTAssertTrue(element(identifier: "bugReport.openIssue").exists, "the bug reporter cannot open an issue", file: file, line: line)

        let cancel = button(label: "Cancel")
        XCTAssertTrue(cancel.exists, "the bug reporter has no Cancel", file: file, line: line)
        cancel.click()
        XCTAssertTrue(waitUntil(timeout: 10) { !title.exists }, "Cancel did not close the bug reporter", file: file, line: line)
    }
}
