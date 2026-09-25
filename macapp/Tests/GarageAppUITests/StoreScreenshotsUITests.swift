import AppKit
import XCTest

/// Mac App Store screenshots: the main pages at a 1440 × 900 point window (2880 × 1800 pixels on a
/// Retina display, 1440 × 900 on a standard one; both are store sizes), in light and dark mode,
/// over a made-up corpus in the test's own data folder rather than anyone's real files.
///
/// Opt-in, because it downloads an embedding model and takes several minutes. Set
/// `GARAGE_STORE_SCREENSHOTS` to a folder (with `xcodebuild test`, `TEST_RUNNER_GARAGE_STORE_SCREENSHOTS`):
///
///     TEST_RUNNER_GARAGE_STORE_SCREENSHOTS=$HOME/Desktop/store-screenshots \
///       xcodebuild test -project macapp/Garage.xcodeproj -scheme GarageAppUITests \
///       -only-testing:GarageAppUITests/StoreScreenshotsUITests
///
/// Each page is written there as `<nn>-<page>-<appearance>.png` and also kept as an attachment in
/// the result bundle. The display needs room for a 1440 × 900 window below the menu bar. Hide the
/// Dock or other windows if they would show behind a page; only the window is captured.
final class StoreScreenshotsUITests: GarageUITestCase {
    static let outputVariable = "GARAGE_STORE_SCREENSHOTS"
    static let windowSize = CGSize(width: 1440, height: 900)
    /// The small preset embedding model: a quick download, and enough to show hybrid search.
    static let embeddingModel = "mxbai-embed-xsmall"
    static let sourceSlug = "field-notes"
    static let query = "how does the tide gauge calibration work"

    private var appearance = "light"
    private var outputFolder: URL!

    override var additionalLaunchArguments: [String] { ["--appearance", appearance] }

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment[Self.outputVariable] ?? ""
        try XCTSkipIf(path.isEmpty, "Set \(Self.outputVariable) to a folder to take the App Store screenshots.")
        outputFolder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try super.setUpWithError()
        // One page that fails to load should not cost the rest of the set.
        continueAfterFailure = true
    }

    func testLightScreenshots() throws {
        appearance = "light"
        try takeScreenshots()
    }

    func testDarkScreenshots() throws {
        appearance = "dark"
        try takeScreenshots()
    }

    // MARK: - The run

    private func takeScreenshots() throws {
        let notes = try makeFolder(named: "Field Notes", files: Self.demoFiles)
        try launchApp()
        waitForBackend()
        try sizeWindow()

        addCustomSource(slug: Self.sourceSlug, root: notes)
        let scanIngest = element(identifier: "sources.row.\(Self.sourceSlug).scanIngest")
        XCTAssertTrue(waitForEnabled(scanIngest), "Scan & Ingest stayed disabled")
        click(scanIngest)

        open(section: "status")
        let documents = element(identifier: "status.figure.documents")
        XCTAssertTrue(
            waitUntil(timeout: 300) { documents.exists && self.shownText(of: documents) == "\(Self.demoFiles.count)" },
            "the Status page never counted all \(Self.demoFiles.count) demo files"
        )

        registerAndEmbed()

        open(section: "status")
        settle()
        capture("01-status")

        open(section: "search")
        runSearch()
        capture("02-search")

        open(section: "sources")
        settle()
        capture("03-sources")

        open(section: "documents")
        XCTAssertTrue(element(text: "Tide Gauge Calibration").waitForExistence(timeout: 30), "Documents does not list the demo notes")
        settle()
        capture("04-documents")

        open(section: "models")
        settle()
        capture("05-models")

        open(section: "mcp")
        _ = waitUntil(timeout: 60) { self.element(identifier: "mcp.stop").exists }
        settle()
        capture("06-mcp-server")
    }

    /// Registers the small embedding model from the Models page and embeds the corpus with it, so
    /// the Search page shows hybrid results. The model downloads on first use.
    private func registerAndEmbed() {
        open(section: "models")
        let manageEmbedding = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manageEmbedding.waitForExistence(timeout: 15), "the Models page has no Embedding card")
        click(manageEmbedding)

        let add = element(identifier: "models.add.\(Self.embeddingModel)")
        XCTAssertTrue(add.waitForExistence(timeout: 30), "the Embedding tab does not offer \(Self.embeddingModel)")
        XCTAssertTrue(waitForEnabled(add), "Register \(Self.embeddingModel) stayed disabled")
        click(add)
        XCTAssertTrue(
            element(identifier: "models.row.\(Self.embeddingModel)").waitForExistence(timeout: 60),
            "\(Self.embeddingModel) did not appear among the registered models"
        )

        // Embed All sits on the Overall segment.
        let segments = element(identifier: "models.tab").radioButtons
        if segments.count > 0 {
            segments.element(boundBy: 0).click()
        }
        let embedAll = element(identifier: "models.embedAll")
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 60), "Embed All stayed disabled with a registered model")
        click(embedAll)
        // Embedding runs until the button is offered again.
        _ = waitUntil(timeout: 5) { !embedAll.isEnabled }
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 900), "embedding the demo corpus did not finish")
    }

    /// Runs the demo query and waits for ranked results. The shot is still taken when none come, so
    /// the run shows what the page said instead.
    private func runSearch() {
        let field = element(identifier: "search.query")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no search field")
        // The plain-style field only takes focus when the click lands on its text area.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeText(Self.query + "\n")
        let found = element(text: "#1").waitForExistence(timeout: 120)
        XCTAssertTrue(found, "the demo query returned no ranked results")
        settle()
    }

    // MARK: - Window and capture

    /// Moves the main window to the top left of its screen and resizes it to exactly
    /// `windowSize` points by dragging its title bar and its bottom-right corner.
    private func sizeWindow(file: StaticString = #filePath, line: UInt = #line) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "no main window", file: file, line: line)

        // Title bar to just below the menu bar, near the left edge.
        let frame = window.frame
        let grab = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.width / 2, dy: 12))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40 - frame.minX + frame.width / 2, dy: 40 - frame.minY + 12))
        grab.press(forDuration: 0.3, thenDragTo: target)

        // A few passes: the window may clamp or snap the first drag.
        for _ in 0..<4 {
            let current = window.frame
            if current.size == Self.windowSize { break }
            let corner = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: current.width - 2, dy: current.height - 2))
            let goal = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: Self.windowSize.width - 2, dy: Self.windowSize.height - 2))
            corner.press(forDuration: 0.3, thenDragTo: goal)
        }
        XCTAssertEqual(
            window.frame.size,
            Self.windowSize,
            "the window did not reach \(Int(Self.windowSize.width)) × \(Int(Self.windowSize.height)) points; is the display big enough?",
            file: file,
            line: line
        )
    }

    /// Gives the page a moment to finish animating and loading before it is captured.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    /// Captures the main window as `<name>-<appearance>.png` in the output folder and as a kept
    /// attachment.
    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.size, Self.windowSize, "the window changed size before \(name)", file: file, line: line)
        let screenshot = window.screenshot()
        let fileName = "\(name)-\(appearance)"

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = outputFolder.appendingPathComponent(fileName).appendingPathExtension("png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)", file: file, line: line)
        }
        if let rep = NSBitmapImageRep(data: screenshot.pngRepresentation) {
            XCTContext.runActivity(named: "\(fileName): \(rep.pixelsWide) × \(rep.pixelsHigh) pixels") { _ in }
        }
    }

    // MARK: - Demo corpus

    /// A made-up field-station notebook: Markdown notes, a plain-text log and a little code, so the
    /// Documents page shows a mix and the query has something to find.
    static let demoFiles: [String: String] = [
        "tide-gauge-calibration.md": """
        # Tide Gauge Calibration

        The harbor gauge is calibrated against the benchmark on the east pier every spring. We level
        from the benchmark to the gauge's reference mark, then compare a week of readings with the
        staff gauge to find the offset. The offset is entered in the station config and applied to
        every reading from then on.

        ## Checklist

        - Level from benchmark BM-7 to the gauge reference mark
        - Record staff gauge readings at slack water, twice a day for seven days
        - Compute the mean offset and its standard deviation
        - Update `station.toml` and note the change in the log
        """,
        "kelp-survey-2026.md": """
        # Kelp Survey 2026

        Canopy cover in the north cove fell 12% from last year, while the south transect held steady.
        Urchin counts were highest where the canopy thinned, which matches the pattern from 2024.
        Next season we add two transects near the breakwater and repeat the drone passes monthly.
        """,
        "weather-station-notes.md": """
        # Weather Station Notes

        The anemometer on the mast started under-reading in August. Replacing the bearing fixed it;
        readings now agree with the backup cup anemometer within 0.3 m/s. The rain gauge funnel
        needs clearing after every storm, or it overflows and under-counts heavy rain.
        """,
        "grant-proposal-draft.md": """
        # Grant Proposal Draft: Coastal Monitoring Network

        We propose linking the harbor tide gauge, the weather mast and three new buoys into one
        network that publishes open data every ten minutes. The station already runs the gauge and
        the mast; the grant covers the buoys, their moorings and two years of maintenance.
        """,
        "meeting-notes-sept.md": """
        # Meeting Notes, September

        Attendees: Priya, Tomás, Wen. Agreed to move the buoy deployment to October, after the
        storm season peak. Wen will finish the calibration write-up; Tomás orders mooring chain.
        Open question: can the old data logger handle the higher sample rate?
        """,
        "field-log.txt": """
        2026-09-02  Low tide 06:14. Staff gauge 0.42 m, harbor gauge 0.40 m. Offset holds.
        2026-09-09  Replaced anemometer bearing. Checked against the cup anemometer.
        2026-09-16  Kelp transect N3: canopy thin, urchins dense near the rocks.
        2026-09-23  Cleared the rain gauge funnel after the storm. Logger battery at 71%.
        """,
        "tide_offset.py": """
        \"\"\"Compute the tide gauge offset from paired staff and gauge readings.\"\"\"

        from statistics import mean, stdev


        def gauge_offset(staff: list[float], gauge: list[float]) -> tuple[float, float]:
            \"\"\"Mean and standard deviation of staff minus gauge, in metres.\"\"\"
            if len(staff) != len(gauge) or len(staff) < 2:
                raise ValueError("need at least two paired readings")
            differences = [s - g for s, g in zip(staff, gauge)]
            return mean(differences), stdev(differences)
        """,
        "reading-list.md": """
        # Reading List

        - Pugh & Woodworth, *Sea-Level Science*: chapter 3 on gauge datums
        - The station's 2019 calibration report, for the old benchmark survey
        - Notes on kelp forest recovery after urchin barrens
        """,
    ]
}
