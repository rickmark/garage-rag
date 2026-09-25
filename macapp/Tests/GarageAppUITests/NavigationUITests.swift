import XCTest

/// The sidebar reaches every page, and each page renders its own content.
final class NavigationUITests: GarageUITestCase {

    /// Each `AppSection` case name, with a piece of text only that page shows.
    private static let pages: [(section: String, marker: String)] = [
        ("status", "Corpus & Pipeline Overview"),
        ("database", "Schema & Migrations"),
        ("sources", "Add a Source"),
        ("documents", "Filter by title or URI…"),
        ("facts", "Search facts…"),
        ("models", "Embed All"),
        ("mcp", "MCP Server Status"),
        ("search", "Search corpus (e.g., 'system architecture', 'API design')…"),
        ("logs", "Log Source"),
    ]

    func testSidebarOpensEveryPage() throws {
        try launchApp()

        for page in Self.pages {
            open(section: page.section)
            XCTAssertTrue(
                element(text: page.marker).waitForExistence(timeout: 15),
                "the \(page.section) page did not show \"\(page.marker)\""
            )
        }
    }

    func testMainWindowOpensOnStatusWithoutSplashOrSetup() throws {
        try launchApp()

        XCTAssertTrue(element(identifier: "sidebar.status").waitForExistence(timeout: 15), "no sidebar")
        XCTAssertFalse(app.buttons["splash.continue"].exists, "the splash showed although it was turned off")
        XCTAssertFalse(element(identifier: "firstRun.root").exists, "the setup assistant showed although setup was complete")
        XCTAssertTrue(element(text: "Corpus & Pipeline Overview").waitForExistence(timeout: 15), "the window did not open on Status")
    }
}
