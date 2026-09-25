import XCTest

/// The Logs page's table: filling it from the app's own OSLog entries and from an ingest, narrowing
/// it with the text filter, resetting the filters and clearing a source.
final class LogsUITests: GarageUITestCase {

    /// The "visible of total entries" badge as two numbers, or nil while it is not shown.
    private func counts() -> (visible: Int, total: Int)? {
        let badge = element(identifier: "logs.count")
        guard badge.exists else { return nil }
        let numbers = shownText(of: badge).split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    private func selectSource(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "logs.source").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) log source", file: file, line: line)
        segment.click()
    }

    /// The live stream starts paused; "Fetch OSLog" reads this process's recent entries instead.
    private func fetchRecentOSLog(file: StaticString = #filePath, line: UInt = #line) {
        let fetch = element(identifier: "logs.fetch")
        XCTAssertTrue(fetch.waitForExistence(timeout: 10), "Logs has no Fetch OSLog menu", file: file, line: line)
        fetch.click()
        let item = app.menuItems["Fetch Past 15 mins"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Fetch OSLog offers no 15-minute window", file: file, line: line)
        item.click()
    }

    private func filter(by text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier: "logs.filter")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Logs has no filter field", file: file, line: line)
        let focused = waitUntil(timeout: 15) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
            return waitUntil(timeout: 1) { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        }
        XCTAssertTrue(focused, "the filter field never took keyboard focus", file: file, line: line)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// The first row's longest text, which is its message.
    private func firstRowMessage() -> String? {
        let row = app.tables.firstMatch.tableRows.firstMatch
        guard row.waitForExistence(timeout: 10) else { return nil }
        let texts = row.staticTexts.allElementsBoundByIndex.map { shownText(of: $0) }
        return texts.max { $0.count < $1.count }
    }

    /// Fetching the app's recent OSLog fills the Unified Log; a phrase from one row narrows the table
    /// to the rows holding it, a phrase from nowhere empties it, and Reset Filters brings it all back.
    func testTableFillsAndTheTextFilterNarrowsIt() throws {
        try launchApp()
        waitForBackend()
        open(section: "logs")
        selectSource("Unified Log")
        fetchRecentOSLog()

        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "fetching the OSLog left the Unified Log empty")
        let message = try XCTUnwrap(firstRowMessage(), "the table shows no rows")
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let phrase = String(firstLine.prefix(24)).trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(phrase.isEmpty, "the first row has no message")

        filter(by: phrase)
        XCTAssertTrue(
            waitUntil(timeout: 10) { (self.counts()?.visible ?? 0) >= 1 && self.element(identifier: "logs.resetFilters").exists },
            "filtering by \"\(phrase)\" hid the row it came from (\(String(describing: counts())))"
        )
        let narrowed = try XCTUnwrap(counts())
        XCTAssertLessThanOrEqual(narrowed.visible, narrowed.total)

        filter(by: "zq-no-log-line-says-this-9321")
        XCTAssertTrue(waitUntil(timeout: 10) { self.counts()?.visible == 0 }, "a phrase from nowhere left rows (\(String(describing: counts())))")
        XCTAssertTrue(element(text: "No Matches").exists, "an empty filter result does not say so")

        click(element(identifier: "logs.resetFilters"))
        XCTAssertTrue(
            waitUntil(timeout: 10) { self.counts().map { $0.visible == $0.total && $0.total > 0 } ?? false },
            "Reset Filters did not bring every row back (\(String(describing: counts())))"
        )
        XCTAssertFalse(element(identifier: "logs.resetFilters").exists, "Reset Filters stayed with no filter set")
    }

    /// Clear empties the source it is on.
    func testClearEmptiesTheSource() throws {
        try launchApp()
        waitForBackend()
        open(section: "logs")
        selectSource("Unified Log")
        fetchRecentOSLog()
        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "fetching the OSLog left the Unified Log empty")
        let before = try XCTUnwrap(counts()).total

        let clear = element(identifier: "logs.clear")
        XCTAssertTrue(waitForEnabled(clear, timeout: 10), "Clear stayed disabled with rows")
        clear.click()
        // The stream is paused, but a helper service's own log lines still arrive; far fewer, though.
        XCTAssertTrue(
            waitUntil(timeout: 10) { (self.counts()?.total ?? 0) < before || self.element(text: "No Logs Recorded").exists },
            "Clear did not empty the Unified Log (\(before) before, \(String(describing: counts())) after)"
        )
    }

    /// A Scan & Ingest leaves its worker's lines under Ingest, which XPC delivers without the OSLog.
    func testIngestFillsTheIngestSource() throws {
        let notes = try makeFolder(named: "notes", files: ["one.md": "# One\n\nA short note for the ingest log.\n"])
        try launchApp()
        waitForBackend()
        addCustomSource(slug: "uitest-logs", root: notes)
        let scanIngest = element(identifier: "sources.row.uitest-logs.scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        click(scanIngest)

        open(section: "status")
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(waitUntil(timeout: 240) { documents.exists && self.shownText(of: documents) == "1" }, "the note was never ingested")

        open(section: "logs")
        selectSource("Ingest")
        XCTAssertTrue(waitUntil(timeout: 30) { (self.counts()?.total ?? 0) > 0 }, "an ingest left no lines under Ingest")
    }
}
