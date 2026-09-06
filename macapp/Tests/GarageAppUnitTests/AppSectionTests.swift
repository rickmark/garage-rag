import XCTest
@testable import GarageApp

final class AppSectionTests: XCTestCase {

    func testAppSectionAllCasesCount() {
        XCTAssertEqual(AppSection.allCases.count, 5)
    }

    func testAppSectionIdentifiers() {
        XCTAssertEqual(AppSection.status.id, "Status")
        XCTAssertEqual(AppSection.sources.id, "Sources & Ingest")
        XCTAssertEqual(AppSection.models.id, "Models")
        XCTAssertEqual(AppSection.search.id, "Search")
        XCTAssertEqual(AppSection.logs.id, "Logs")
    }

    func testAppSectionSymbols() {
        XCTAssertEqual(AppSection.status.symbol, "gauge.with.dots.needle.50percent")
        XCTAssertEqual(AppSection.sources.symbol, "tray.and.arrow.down")
        XCTAssertEqual(AppSection.models.symbol, "cpu")
        XCTAssertEqual(AppSection.search.symbol, "magnifyingglass")
        XCTAssertEqual(AppSection.logs.symbol, "terminal")
    }
}
