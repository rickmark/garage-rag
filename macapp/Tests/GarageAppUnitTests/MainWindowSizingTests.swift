import AppKit
import XCTest
@testable import GarageApp

/// The frame the main window grows to when the setup assistant closes.
final class MainWindowSizingTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1080)
    private let target = NSSize(width: 1100, height: 760)

    func testGrowsToTheWorkingSizeAroundTheSameCentre() throws {
        let current = NSRect(x: 400, y: 300, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertEqual(frame.size, target)
        XCTAssertEqual(frame.midX, current.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, current.midY, accuracy: 0.5)
    }

    func testNeverShrinksAWindowTheUserMadeBigger() {
        let current = NSRect(x: 100, y: 100, width: 1400, height: 900)

        XCTAssertNil(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))
    }

    func testGrowsOnlyTheShortSide() throws {
        let current = NSRect(x: 100, y: 100, width: 1300, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertEqual(frame.width, 1300)
        XCTAssertEqual(frame.height, 760)
    }

    func testStaysOnScreenNearAnEdge() throws {
        let current = NSRect(x: 1600, y: 0, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: screen, target: target))

        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertEqual(frame.size, target)
    }

    func testFitsASmallScreen() throws {
        let small = NSRect(x: 0, y: 25, width: 1024, height: 700)
        let current = NSRect(x: 100, y: 100, width: 760, height: 520)

        let frame = try XCTUnwrap(MainWindowSizing.frameAfterFirstRun(current: current, visible: small, target: target))

        XCTAssertEqual(frame.size, NSSize(width: 1024, height: 700))
        XCTAssertEqual(frame.origin, small.origin)
    }
}
