import XCTest

/// The Sources page: adding and removing a source, its toolbar, and an end-to-end ingest of a
/// small folder of Markdown files.
final class SourcesUITests: GarageUITestCase {

    private let slug = "uitest-notes"

    /// A folder of Markdown files inside this test's data folder, so the source never points at real files.
    private func makeNotesFolder(files: [String: String]) throws -> URL {
        let folder = dataDirectory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, body) in files {
            try Data(body.utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func addSource(root: URL, file: StaticString = #filePath, line: UInt = #line) {
        open(section: "sources", file: file, line: line)
        let slugField = element(identifier: "sources.form.slug")
        XCTAssertTrue(slugField.waitForExistence(timeout: 15), "no slug field", file: file, line: line)
        replaceText(in: slugField, with: slug)
        replaceText(in: element(identifier: "sources.form.root"), with: root.path)

        let submit = element(identifier: "sources.form.submit")
        XCTAssertTrue(waitForEnabled(submit), "Add / Update Source stayed disabled", file: file, line: line)
        submit.click()
        XCTAssertTrue(
            element(identifier: "sources.row.\(slug)").waitForExistence(timeout: 30),
            "the new source did not appear in the list",
            file: file,
            line: line
        )
    }

    func testToolbarOffersCombinedActions() throws {
        try launchApp()
        waitForBackend()
        open(section: "sources")

        XCTAssertTrue(element(text: "No sources configured yet.").waitForExistence(timeout: 15), "no empty state on a new folder")
        let scanIngestAll = element(identifier: "sources.scanIngestAll")
        XCTAssertTrue(scanIngestAll.exists, "no Scan & Ingest All button")
        XCTAssertFalse(scanIngestAll.isEnabled, "Scan & Ingest All is enabled with no sources")
        XCTAssertTrue(element(identifier: "sources.sync").exists, "no sync button")
        XCTAssertTrue(element(identifier: "sources.diskAccess.refresh").exists, "no disk access refresh button")

        // Folded into the buttons above.
        for retired in ["Refresh Sources", "Scan All Sources", "Ingest All Sources", "Sync Config → DB", "Import DB → Config", "Test Ingest Paths & Disk Access"] {
            XCTAssertFalse(button(label: retired).exists, "the retired \"\(retired)\" button is back")
        }
    }

    func testAddAndRemoveSource() throws {
        let notes = try makeNotesFolder(files: ["one.md": "# One\n\nA note.\n"])
        try launchApp()
        waitForBackend()

        addSource(root: notes)
        XCTAssertFalse(element(text: "No sources configured yet.").exists, "the empty state stayed after adding a source")

        // The form still names the source it just added.
        let remove = element(identifier: "sources.form.remove")
        XCTAssertTrue(waitForEnabled(remove), "Remove Source stayed disabled")
        remove.click()
        XCTAssertTrue(
            waitUntil(timeout: 30) { !self.element(identifier: "sources.row.\(self.slug)").exists },
            "the removed source stayed in the list"
        )
        XCTAssertTrue(element(text: "No sources configured yet.").waitForExistence(timeout: 15), "no empty state after removing the only source")
    }

    func testSyncKeepsConfigAndDatabaseInStep() throws {
        let notes = try makeNotesFolder(files: ["one.md": "# One\n"])
        try launchApp()
        waitForBackend()
        addSource(root: notes)

        // Adding a source registers it in the database only; garage.json is untouched until a sync.
        XCTAssertFalse(try String(contentsOf: configFile, encoding: .utf8).contains(slug), "adding a source wrote garage.json")

        let sync = element(identifier: "sources.sync")
        XCTAssertTrue(waitForEnabled(sync), "the sync button stayed disabled")
        sync.click()
        // Sync copies the database-only source into the test folder's garage.json (two RPCs in turn).
        XCTAssertTrue(
            waitUntil(timeout: 30) { ((try? String(contentsOf: self.configFile, encoding: .utf8)) ?? "").contains(self.slug) },
            "sync did not copy the source into garage.json"
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(identifier: "sources.row.\(slug)").count, 1,
            "the source is not listed exactly once after sync"
        )
    }

    /// Scan & Ingest on a folder of two notes ends with both documents in the corpus: the Status
    /// page counts them and the Documents page lists them.
    func testScanAndIngestIndexesTheFolder() throws {
        let notes = try makeNotesFolder(files: [
            "alpha.md": "# Alpha note\n\nGarage keeps a local index of personal documents.\n",
            "beta.md": "# Beta note\n\nHybrid search fuses keyword and vector results.\n",
        ])
        try launchApp()
        waitForBackend()
        addSource(root: notes)

        let scanIngest = element(identifier: "sources.row.\(slug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        scanIngest.click()

        open(section: "status")
        XCTAssertTrue(
            element(textBeginningWith: "All 2 docs ingested").waitForExistence(timeout: 240),
            "the Status page never reported both notes ingested"
        )

        open(section: "documents")
        XCTAssertTrue(element(text: "Alpha note").waitForExistence(timeout: 30), "Documents does not list the first note")
        XCTAssertTrue(element(text: "Beta note").exists, "Documents does not list the second note")
    }
}
