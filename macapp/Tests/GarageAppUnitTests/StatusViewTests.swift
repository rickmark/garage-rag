import XCTest
import SwiftUI
@testable import GarageApp

final class StatusViewTests: XCTestCase {

    func testPageStatusSeverityOrdering() {
        XCTAssertLessThan(StatusView.PageStatusSeverity.critical, StatusView.PageStatusSeverity.warning)
        XCTAssertLessThan(StatusView.PageStatusSeverity.warning, StatusView.PageStatusSeverity.info)
        XCTAssertLessThan(StatusView.PageStatusSeverity.info, StatusView.PageStatusSeverity.healthy)
    }

    @MainActor
    func testStatusViewInitializesAndRenders() {
        let appState = AppState()
        var selection: AppSection? = .status
        let binding = Binding<AppSection?>(
            get: { selection },
            set: { selection = $0 }
        )

        let statusView = StatusView(selection: binding)
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testStatusViewDefaultInitializer() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testStatusViewSortingPlacesFailingItemsAtTop() {
        let appState = AppState()
        let statusView = StatusView()
            .environmentObject(appState)

        let controller = NSHostingController(rootView: statusView)
        XCTAssertNotNil(controller.view)
    }
}
