import XCTest
@testable import GarageApp

final class AppSectionTests: XCTestCase {

    func testAppSectionAllCasesCount() {
        XCTAssertEqual(AppSection.allCases.count, 7)
    }

    func testAppSectionIdentifiers() {
        XCTAssertEqual(AppSection.status.id, "Status")
        XCTAssertEqual(AppSection.database.id, "Database")
        XCTAssertEqual(AppSection.sources.id, "Sources & Ingest")
        XCTAssertEqual(AppSection.models.id, "Models")
        XCTAssertEqual(AppSection.mcp.id, "MCP Server")
        XCTAssertEqual(AppSection.search.id, "Search")
        XCTAssertEqual(AppSection.logs.id, "Logs")
    }

    func testAppSectionSymbols() {
        XCTAssertEqual(AppSection.status.symbol, "gauge.with.dots.needle.50percent")
        XCTAssertEqual(AppSection.database.symbol, "cylinder.split.1x2")
        XCTAssertEqual(AppSection.sources.symbol, "tray.and.arrow.down")
        XCTAssertEqual(AppSection.models.symbol, "cpu")
        XCTAssertEqual(AppSection.mcp.symbol, "server.rack")
        XCTAssertEqual(AppSection.search.symbol, "magnifyingglass")
        XCTAssertEqual(AppSection.logs.symbol, "terminal")
    }
}
