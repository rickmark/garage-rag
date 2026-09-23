import SwiftUI
import XCTest
@testable import GarageApp

final class ProportionalSplitViewTests: XCTestCase {
    private typealias Split = ProportionalSplitView<EmptyView, EmptyView>

    func testLeadingWidthFollowsFraction() {
        XCTAssertEqual(Split.leadingWidth(fraction: 1.0 / 3.0, totalWidth: 1200, minLeading: 260, minTrailing: 340), 400)
    }

    func testLeadingWidthRespectsLeadingMinimum() {
        XCTAssertEqual(Split.leadingWidth(fraction: 1.0 / 3.0, totalWidth: 660, minLeading: 260, minTrailing: 340), 260)
    }

    func testTrailingMinimumWinsWhenBothCannotFit() {
        XCTAssertEqual(Split.leadingWidth(fraction: 1.0 / 3.0, totalWidth: 500, minLeading: 260, minTrailing: 340), 160)
        XCTAssertEqual(Split.leadingWidth(fraction: 0.9, totalWidth: 1000, minLeading: 260, minTrailing: 340), 660)
    }

    func testLeadingWidthNeverNegative() {
        XCTAssertEqual(Split.leadingWidth(fraction: 0.5, totalWidth: 100, minLeading: 0, minTrailing: 340), 0)
    }
}
