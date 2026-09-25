import AppKit
import XCTest

/// Mac App Store screenshots: the main pages at a 1440 × 900 point window (2880 × 1800 pixels on a
/// Retina display, 1440 × 900 on a standard one; both are store sizes), in light and dark mode,
/// over the made-up fixture corpus (`macapp/Tests/Fixtures`) rather than anyone's real files.
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
    static let query = "who kept the lighthouse during the storm"

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
        try launchApp()
        waitForBackend()
        try sizeWindow()

        try ingestFixtureCorpus()
        registerAndEmbed()

        open(section: "search")
        runSearch()
        capture("01-search")

        open(section: "documents")
        XCTAssertTrue(
            element(text: FixtureCorpus.lighthouse.title).waitForExistence(timeout: 30),
            "Documents does not list the fixture corpus"
        )
        settle()
        capture("02-documents")

        open(section: "status")
        settle()
        capture("03-status")

        open(section: "mcp")
        _ = waitUntil(timeout: 60) { self.element(identifier: "mcp.stop").exists }
        settle()
        capture("04-mcp-server")

        open(section: "sources")
        settle()
        capture("05-sources")

        open(section: "models")
        settle()
        capture("06-models")
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
        XCTAssertTrue(waitForEnabled(embedAll, timeout: 900), "embedding the fixture corpus did not finish")
    }

    /// Runs the query and waits for ranked results. The shot is still taken when none come, so
    /// the run shows what the page said instead.
    private func runSearch() {
        let field = element(identifier: "search.query")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "no search field")
        // The plain-style field only takes focus when the click lands on its text area.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        app.typeText(Self.query + "\n")
        let found = element(text: "#1").waitForExistence(timeout: 120)
        XCTAssertTrue(found, "the query returned no ranked results")
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
}
